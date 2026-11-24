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
//! is who has the entity spawned, `stale` who of them missed a delta and needs it whole. Kinds take
//! the differences, send what they send in their own order, and confirm what was accepted: what
//! was not is offered again.
//!
//! Every player stands at an anchor, where it last was more than `slack` blocks from: around it,
//! each column is, for each tracking range, wholly within reach of the player wherever it goes
//! until it moves that far again (yes), wholly out of reach (no), or neither (edge). Those answers
//! are bits of player masks kept for every column of the tiles where tracked entities are, so an
//! entity that moves is answered by its column's masks, and only its edge players are measured;
//! a player that moves measures only the entities of its edge columns; one that leaves its slack
//! is anchored again, and only columns whose answer changed are looked at. With nothing moving,
//! nothing is done.
//!
//! An entity some client still knows keeps its directory slot, and with it its network id,
//! until every such client was told it is gone.

const std = @import("std");
const entities_module = @import("entities");
const lightning_rod = @import("lightning_rod");
const Players = @import("players").players.Players;
const Streaming = @import("terrain").streaming.Streaming;
const geometry_bounds = @import("occlusion").bounds;
const PlayerChanges = @import("player_changes.zig").PlayerChanges;

const bit_sets = lightning_rod.system.bit_sets;
const Entities = entities_module.Entities;
const Array = entities_module.Array;
const Records = entities_module.extras.Records;
const Entry = entities_module.space.Entry;
const Feet = entities_module.space.Feet;
const Boxed = entities_module.space.Boxed;
const Block = entities_module.space.Block;
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
        /// Tiles of columns tracking keeps masks for at most.
        tiles: u32 = 4096,
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
        /// Where one of its boxed entities is now: tracking asks only where a box leaves an answer
        /// unsure. Kinds that box their entities give it.
        exact: ?Exact = null,
    };

    /// Where a boxed entity is now, from its kind: without side effects, as tracking asks it
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

    /// How a column stands against a player's anchor, for one range: wholly within reach wherever
    /// the player is within its slack, wholly out of it, or neither.
    const Class = enum(u2) { no, edge, yes };

    pub const TrackerId = u8;
    const max_trackers = 32;
    const max_groups = 16;
    const no_tracker = std.math.maxInt(u8);
    const none = std.math.maxInt(u32);
    const no_owner = std.math.maxInt(u16);

    /// How far a player goes from its anchor before it is anchored again.
    pub const slack = 6.0;

    /// Trackers of one range, answered by the same masks.
    const Group = struct { range: f64, kinds: Kinds };

    const Tracker = struct {
        kinds: Kinds,
        range: f64,
        max_range: f64,
        group: u8,
        exact: ?Exact,
    };

    /// Columns of a tile on a side.
    const tile_side = 8;
    const tile_columns = tile_side * tile_side;

    /// Eight by eight columns: which of them hold tracked entities or boxes, as last seen, and the
    /// space's index of each, as last found.
    const Tile = struct {
        world: u32,
        x: i32,
        z: i32,
        generation: u32,
        occupied: u64 = 0,
        index: [tile_columns]u32 = @splat(none),
        made: [tile_columns]u64 = @splat(0),
    };
    const TileBucket = struct { key: u128 = 0, at: u32 = none };

    /// An edge column of a player for one range, while the tile is the same.
    const EdgeRef = struct { tile: u32, generation: u32, column: u8, group: u8 };

    const PlayerBounds = struct { world: u32, low: [2]f64, high: [2]f64 };
    const bounds_max = 8;
    const any_world = std.math.maxInt(u32);
    const SeenKey = struct { world: u32, x: i32, z: i32, footprint: Footprint };
    /// A multiply and a fold: keys are small integers, asked of many times a tick.
    const SeenContext = struct {
        pub fn hash(_: SeenContext, key: SeenKey) u64 {
            var mixed: u64 = @as(u64, key.world) *% 0x9e3779b97f4a7c15;
            for ([_]i32{ key.x, key.z, key.footprint.low[0], key.footprint.low[1], key.footprint.low[2], key.footprint.high[0], key.footprint.high[1], key.footprint.high[2] }) |part| mixed = (mixed ^ @as(u32, @bitCast(part))) *% 0xc2b2ae3d27d4eb4f;
            return mixed ^ (mixed >> 29);
        }
        pub fn eql(_: SeenContext, a: SeenKey, b: SeenKey) bool {
            return std.meta.eql(a, b);
        }
    };
    /// Footprints one tick shares; past them each entity asks alone.
    const shared_footprints = 4096;

    /// What tracking keeps of an entity beside its rows.
    const Meta = struct {
        tracker: u8 = no_tracker,
        /// The entity the rest is about, as a slot comes to hold another.
        entity: u64 = 0,
        /// Its entry in this tick's work, or none.
        work: u32 = none,
        /// The pass it was last looked at, so a log naming it twice costs once.
        looked: u64 = 0,
        /// Gone from the space, its removal owed to whoever still knows it.
        gone: bool = false,
        /// The pass it last joined the unsettled, so it joins once.
        unsettled: u64 = 0,
        /// The pass a kind was told an entity is settled anywhere in a box, and the box: boxed
        /// there that pass, it needs no asking again.
        settled_for: u64 = 0,
        settled_box: Feet = .{ .low = .{ 0, 0, 0 }, .high = .{ 0, 0, 0 } },
        /// The players heard when it was settled: heard again since, the answer may be another.
        settled_heard: u64 = 0,
        /// What the entity says of itself, which the rule reads: its own range, scaled, where it
        /// is not its type's (getEffectiveRange with passengers); the player it is, who never
        /// sees itself; whether only spectators see it (ServerPlayer.broadcastToPlayer); and
        /// whether only the players of its allowed row may.
        range: f64 = 0,
        owner: u16 = no_owner,
        spectators_only: bool = false,
        restricted: bool = false,
        /// Where it was last answered for every player: a point's column and footprint, which its
        /// answers for players not at an edge depend on.
        placed: bool = false,
        world: u32 = 0,
        column: [2]i32 = .{ 0, 0 },
        footprint: Footprint = .{},
        /// The tile of that column, while it is the same tile.
        tile: u32 = none,
        tile_generation: u32 = 0,
    };

    /// A change of one entity's audience to send: whom to spawn it for, whom to remove it from,
    /// and whether it is gone.
    pub const Change = struct {
        slot: u32,
        spawn: bit_sets.Set,
        remove: bit_sets.Set,
        gone: bool,
    };

    /// What tracking did, for measuring it against what had to be done.
    pub const Stats = struct {
        passes: u64 = 0,
        /// Entities placed, moved, removed or boxed, as the log told.
        logged: u64 = 0,
        /// Of those, answered without measuring anything.
        logged_quiet: u64 = 0,
        /// Players anchored again, and players that moved within their slack.
        anchored: u64 = 0,
        slack_moves: u64 = 0,
        /// Columns looked at for a player, and entities measured in them.
        columns: u64 = 0,
        measured: u64 = 0,
        /// Pairs whose answer was asked whole, and of them those that changed.
        asked: u64 = 0,
        changed: u64 = 0,
        /// Near entities measured, and every entity of edge columns measured again.
        near_measured: u64 = 0,
        edge_walks: u64 = 0,
        /// Boxes answered for a player, and kinds asked where an entity is.
        boxes: u64 = 0,
        exact: u64 = 0,
        tiles_made: u64 = 0,
    };

    deps: Dependencies,
    config: Configuration,
    changes: PlayerChanges,
    trackers: [max_trackers]Tracker = undefined,
    tracker_count: usize = 0,
    tracker_of: [Kinds.max_kinds]u8 = @splat(no_tracker),
    tracked: Kinds = .{},
    groups: [max_groups]Group = undefined,
    group_count: usize = 0,
    /// Boxed entities some player was unsure of this tick: asked again the next.
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
    /// Each entry's tracker, beside it, so a kind walks its own without reading the rest.
    work_trackers: Array(u8),
    work_rows: Array(u64),
    /// Whether each entry holds answers, being worked out this pass, rather than the spawns and
    /// removals owed; those opened this pass, finalized at its end; and how many hold nothing.
    work_open: Array(u8),
    opened: Array(u32),
    work_empty: usize = 0,
    work_overflowed: bool = false,
    /// Slots asked about again next pass, as what they said of themselves changed or a box of
    /// theirs was unsure.
    retry: Array(u32),
    /// Slots of entities gone that clients still know.
    gone: Array(u32),
    /// Slots of entities with ranges of their own, asked of every player each pass.
    own_ranged: Array(u32),
    /// This tick's footprints whose sight was asked: for each, the players asked and those who see.
    seen_footprints: std.HashMapUnmanaged(SeenKey, u32, SeenContext, 80),
    seen_rows: []u64,
    seen_count: usize = 0,
    /// The players, as tracking hears them each tick.
    xs: []f64,
    zs: []f64,
    reaches: []f64,
    worlds: []u32,
    ready: []bool,
    spectating: []bool,
    /// Where each player last measured every entity of its edge columns, and its near entities
    /// then: those within `near_band` of its reach, each with the reach it is measured by,
    /// squared, and whether it was within it last time, side by side for a test a vector at a
    /// time; and the boxes of its edge columns. Past room, it measures every edge entity the next
    /// time it moves.
    measure_x: []f64,
    measure_z: []f64,
    near_chunks: [][]NearChunk,
    near_count: []usize,
    near_boxes: [][]u32,
    near_box_count: []usize,
    near_full: []bool,
    /// How many near entities each player had when it last gathered them: grown twice that, by
    /// entities moving near its reach, its near entities are gathered afresh.
    near_gathered: []usize,
    /// Each player's anchor, and its reach and world then.
    anchor_x: []f64,
    anchor_z: []f64,
    anchor_reach: []f64,
    anchor_world: []u32,
    anchored: []bool,
    /// Each player's edge columns holding tracked entities, found when it was anchored and as
    /// columns filled since.
    edges: []Array(EdgeRef),
    /// Tiles by their index, found by hash, and their masks: for every column of a tile, for each
    /// range, the yes row then the edge row of players.
    tiles: Records(Tile),
    tile_buckets: Array(TileBucket),
    tile_masks: Array(u64),
    tile_stride: usize = 0,
    tile_generation: u32 = 0,
    /// The tile last found, and its key.
    last_tile: u32 = none,
    last_tile_key: u128 = 0,
    /// Per box of the space, the pass and player it was last answered for.
    box_stamps: Array(u64),
    /// The box around each world's ready players this tick, horizontally: an entity whose reach
    /// misses it is seen by no one, without looking for players. Past room for worlds, the last
    /// stands for every other and covers everything.
    bounds: [bounds_max]PlayerBounds = undefined,
    bounds_count: usize = 0,
    /// Whether the players were heard since the bounds were gathered.
    bounds_stale: bool = true,
    /// For entities only some players may see, those players, by slot.
    allowed: Array(u64),
    scratch: []u64,
    /// A row of nobody, for slots never tracked.
    zeros: []u64,
    tick_count: u64 = 0,
    /// Passes that heard the players.
    heard_count: u64 = 0,
    /// Players as subjects too, once asked: each in the space while in its world, by a slot of
    /// its own, its tracker's and its kind.
    player_tracker: ?TrackerId = null,
    player_kind: u32 = 0,
    player_slots: []u32,
    player_ids: []u64,
    /// Whether each was last told tracking it is in spectator mode.
    subject_spectator: []bool,
    /// Where each was placed, whether it moved or was placed this pass, and whether placed anew.
    subject_at: [][3]f64,
    subject_world: []u32,
    subject_moved: []bool,
    subject_fresh: []bool,
    finalized: bool = false,
    /// Whether the entities placed before tracking began were looked at.
    primed: bool = false,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Tracking {
        if (config.range_percentage < 10 or config.range_percentage > 1000 or config.work == 0 or config.tiles == 0) return error.InvalidConfiguration;
        const self = try allocator.create(Tracking);
        const count = deps.players.records.len;
        // A power of two, so a slot's rows never straddle a page.
        const words = try std.math.ceilPowerOfTwo(usize, @max(1, std.math.divCeil(usize, count, 64) catch unreachable));
        const pool = &deps.entities.pool;
        var seen_footprints: std.HashMapUnmanaged(SeenKey, u32, SeenContext, 80) = .empty;
        try seen_footprints.ensureTotalCapacity(allocator, shared_footprints);
        const edges = try allocator.alloc(Array(EdgeRef), count);
        for (edges) |*list| list.* = try .init(allocator, pool);
        self.* = .{
            .deps = deps,
            .config = config,
            .changes = try .init(allocator, count, true),
            .words = words,
            .row_words = std.math.divCeil(usize, count, 64) catch unreachable,
            .rows = try .init(allocator, pool),
            .metas = try .init(allocator, pool),
            .work_slots = try .init(allocator, pool),
            .work_trackers = try .init(allocator, pool),
            .work_open = try .init(allocator, pool),
            .opened = try .init(allocator, pool),
            .work_rows = try .init(allocator, pool),
            .retry = try .init(allocator, pool),
            .unsettled = try .init(allocator, pool),
            .gone = try .init(allocator, pool),
            .own_ranged = try .init(allocator, pool),
            .seen_footprints = seen_footprints,
            .seen_rows = try allocator.alloc(u64, shared_footprints * 2 * words),
            .xs = try allocator.alloc(f64, count),
            .zs = try allocator.alloc(f64, count),
            .reaches = try allocator.alloc(f64, count),
            .worlds = try allocator.alloc(u32, count),
            .ready = try allocator.alloc(bool, count),
            .spectating = try allocator.alloc(bool, count),
            .measure_x = try allocator.alloc(f64, count),
            .measure_z = try allocator.alloc(f64, count),
            .near_chunks = try perPlayer(NearChunk, allocator, count, near_max / near_lanes),
            .near_count = try allocator.alloc(usize, count),
            .near_boxes = try perPlayer(u32, allocator, count, near_boxes_max),
            .near_box_count = try allocator.alloc(usize, count),
            .near_full = try allocator.alloc(bool, count),
            .near_gathered = try allocator.alloc(usize, count),
            .anchor_x = try allocator.alloc(f64, count),
            .anchor_z = try allocator.alloc(f64, count),
            .anchor_reach = try allocator.alloc(f64, count),
            .anchor_world = try allocator.alloc(u32, count),
            .anchored = try allocator.alloc(bool, count),
            .edges = edges,
            .tiles = try .init(allocator, pool),
            .tile_buckets = try .init(allocator, pool),
            .tile_masks = try .init(allocator, pool),
            .box_stamps = try .init(allocator, pool),
            .player_slots = try allocator.alloc(u32, count),
            .player_ids = try allocator.alloc(u64, count),
            .subject_spectator = try allocator.alloc(bool, count),
            .subject_at = try allocator.alloc([3]f64, count),
            .subject_world = try allocator.alloc(u32, count),
            .subject_moved = try allocator.alloc(bool, count),
            .subject_fresh = try allocator.alloc(bool, count),
            .allowed = try .init(allocator, pool),
            .scratch = try allocator.alloc(u64, 4 * words),
            .zeros = try allocator.alloc(u64, words),
        };
        @memset(self.ready, false);
        @memset(self.spectating, false);
        @memset(self.anchored, false);
        @memset(self.near_full, false);
        @memset(self.near_count, 0);
        @memset(self.near_box_count, 0);
        @memset(self.near_gathered, 0);
        @memset(self.player_slots, none);
        @memset(self.player_ids, 0);
        @memset(self.subject_spectator, false);
        @memset(self.subject_moved, false);
        @memset(self.subject_fresh, false);
        @memset(self.zeros, 0);
        // Twice the tiles at most, so a probe ends soon.
        try self.tile_buckets.ensureFilled(try std.math.ceilPowerOfTwo(usize, @as(usize, config.tiles) * 2), .{});
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
        // Players are somewhere, not ticked there; their moves are told by the players.
        self.deps.entities.places.keepsOwnTurns(.of(&.{kind}));
        self.deps.entities.places.space.unlogged_moves.bits.set(kind);
        // Players are not stored with columns: their own column unloaded is no stray.
        self.deps.entities.places.space.unstored.bits.set(kind);
        return tracker;
    }

    /// The slot a player is tracked by as a subject, if it is in its world.
    pub fn playerSlot(self: *const Tracking, player: usize) ?u32 {
        const slot = self.player_slots[player];
        return if (slot == none) null else slot;
    }

    /// Ids of players as subjects, apart from every entity's, which count up from one.
    const player_id_base: u64 = 1 << 63;

    /// Occlusion is asked of the sections a block and a half around a player and three high, as
    /// players replicated before: a looser box than its own, so one at a section's edge does not
    /// come and go.
    const player_shape_half_width = 1.5;
    const player_shape_height = 3;

    /// Players as subjects follow the players: placed while in their world, moved as they move,
    /// gone as they leave it or their connection does.
    fn syncPlayers(self: *Tracking) !void {
        if (self.player_tracker == null) return;
        const space = &self.deps.entities.places.space;
        const shape: entities_module.space.Shape = .{ .kind = self.player_kind, .half_width = player_shape_half_width, .height = player_shape_height };
        for (self.deps.players.records, self.changes.snapshots, 0..) |player, snapshot, index| {
            const entity = player_id_base | (@as(u64, snapshot.generation) << 16) | index;
            // In its world from joining, as vanilla adds a player to its level before the first
            // teleport is confirmed.
            const wanted = player.inWorld();
            if (self.player_slots[index] != none and (!wanted or self.player_ids[index] != entity)) {
                const slot = self.player_slots[index];
                space.remove(self.player_ids[index]);
                self.deps.entities.leave(slot);
                self.player_slots[index] = none;
            }
            if (!wanted) continue;
            const position: [3]f64 = .{ player.position.x, player.position.y, player.position.z };
            if (self.player_slots[index] == none) {
                const slot = try self.deps.entities.enter(entity, self.player_kind);
                self.player_slots[index] = slot;
                self.player_ids[index] = entity;
                self.subject_spectator[index] = false;
                self.subject_fresh[index] = true;
                try self.setOwner(slot, index);
                try space.insert(entity, player.world, position, shape);
                self.subject_moved[index] = true;
            } else {
                // Moved by its slot, which saves finding it by id.
                self.subject_moved[index] = self.subject_world[index] != player.world or !std.meta.eql(self.subject_at[index], position);
                if (self.subject_moved[index]) try space.moveSlot(self.player_slots[index], player.world, position);
            }
            self.subject_at[index] = position;
            self.subject_world[index] = player.world;
            if (self.subject_spectator[index] != snapshot.spectator) {
                self.subject_spectator[index] = snapshot.spectator;
                try self.setSpectatorsOnly(self.player_slots[index], snapshot.spectator);
            }
        }
    }

    /// Players as subjects that moved or were placed, answered from where they were put: their
    /// entries in the log pass.
    fn lookPlayers(self: *Tracking) !void {
        if (self.player_tracker == null) return;
        const shape: entities_module.space.Shape = .{ .kind = self.player_kind, .half_width = player_shape_half_width, .height = player_shape_height };
        for (self.player_slots, self.subject_moved, self.subject_fresh, self.subject_at, self.subject_world, 0..) |slot, went, *fresh, at, world, index| {
            if (slot == none or !went) continue;
            if (slot < self.metas.len and self.metas.at(slot).looked == self.tick_count) continue;
            const entry: Entry = .{ .id = self.player_ids[index], .slot = slot, .section = entities_module.space.coordinate(at[1]), .entered = 0, .position = at, .shape = shape };
            try self.checkPoint(entry, world, fresh.*);
            fresh.* = false;
        }
    }

    /// A tracking layer over entities of its own, for tests of what builds on it.
    pub fn forTests(allocator: std.mem.Allocator, players: *Players) !*Tracking {
        const owned = try Entities.allocate(allocator, std.testing.io, .{ .memory = 1024 * entities_module.pool.page_bytes }, undefined);
        return Tracking.init(allocator, .{ .tiles = 256 }, .{ .entities = owned, .players = players });
    }

    /// A kind's entities are tracked from now on. Call while starting.
    pub fn register(self: *Tracking, spec: Spec) !TrackerId {
        if (self.tracker_count == max_trackers) return error.TooManyTrackers;
        if (self.tile_stride != 0) return error.TrackingStarted;
        const scale = self.config.range_percentage;
        const index: TrackerId = @intCast(self.tracker_count);
        const range: f64 = @floatFromInt(spec.range * scale / 100);
        const max_range: f64 = @floatFromInt((spec.max_range orelse spec.range) * scale / 100);
        // Trackers of one range share their masks.
        const group: u8 = for (self.groups[0..self.group_count], 0..) |*group, at| {
            if (group.range != range) continue;
            group.kinds.bits.setUnion(spec.kinds.bits);
            break @intCast(at);
        } else group: {
            if (self.group_count == max_groups) return error.TooManyTrackers;
            self.groups[self.group_count] = .{ .range = range, .kinds = spec.kinds };
            self.group_count += 1;
            break :group @intCast(self.group_count - 1);
        };
        self.trackers[index] = .{ .kinds = spec.kinds, .range = range, .max_range = max_range, .group = group, .exact = spec.exact };
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

    /// An entity's tracking range: its own, else its type's.
    fn rangeOf(self: *const Tracking, tracker: *const Tracker, slot: u32) f64 {
        const own = if (slot < self.metas.len) self.metas.at(slot).range else 0;
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
        const half: f64 = entry.shape.half_width;
        const low: [3]f64 = .{ entry.position[0] - half, entry.position[1], entry.position[2] - half };
        const high: [3]f64 = .{ entry.position[0] + half, entry.position[1] + entry.shape.height, entry.position[2] + half };
        var result: Footprint = undefined;
        inline for (0..3) |axis| {
            // As blocksOf, whole blocks, at least one.
            const first: i32 = @intFromFloat(@floor(low[axis]));
            const last: i32 = @intFromFloat(@ceil(high[axis]));
            result.low[axis] = first >> 4;
            result.high[axis] = (@max(last, first + 1) - 1) >> 4;
        }
        return result;
    }

    /// updatePlayer's answer for one player, every part of it.
    fn sees(self: *const Tracking, slot: u32, entry: Entry, world: u32, range: f64, player: usize) bool {
        if (!self.ready[player] or self.worlds[player] != world) return false;
        const reach = @min(range, self.reaches[player]);
        const dx = self.xs[player] - entry.position[0];
        const dz = self.zs[player] - entry.position[2];
        if (dx * dx + dz * dz > reach * reach) return false;
        const meta = self.metas.at(slot);
        if (!self.admits(meta, slot, player)) return false;
        const streaming = self.deps.streaming orelse return true;
        const visibility = streaming.snapshotVisibility();
        const record = &self.deps.players.records[player];
        const column = entities_module.space.columnOf(world, entry.position);
        if (!visibility.visible(player, record, world, column.x, column.z)) return false;
        return visibility.boundsVisible(player, record, world, blocksOf(entry));
    }

    /// What an entity says of itself lets a player see it.
    fn admits(self: *const Tracking, meta: *const Meta, slot: u32, player: usize) bool {
        if (meta.owner == player or (meta.spectators_only and !self.spectating[player])) return false;
        return !meta.restricted or has(self.allowedWords(slot), player);
    }

    /// Whether the terrain lets a ready player in the world see an entity of this footprint: its
    /// column sent, and some section of its box not hidden. Asked once a pass for every entity of
    /// a footprint and a player.
    fn terrainLets(self: *Tracking, world: u32, entry: Entry, player: usize) bool {
        if (self.deps.streaming == null) return true;
        const row = self.seenRow(world, entry);
        if (row) |both| if (has(both[0..self.words], player)) return has(both[self.words..], player);
        const seen = self.terrainAnswer(world, entry, player);
        if (row) |both| {
            put(both[0..self.words], player, true);
            put(both[self.words..], player, seen);
        }
        return seen;
    }

    /// The terrain's answer for one player, unkept: its column sent, and some section of its box
    /// not hidden.
    fn terrainAnswer(self: *const Tracking, world: u32, entry: Entry, player: usize) bool {
        const visibility = (self.deps.streaming orelse return true).snapshotVisibility();
        const column = entities_module.space.columnOf(world, entry.position);
        const record = &self.deps.players.records[player];
        return visibility.visible(player, record, world, column.x, column.z) and visibility.boundsVisible(player, record, world, blocksOf(entry));
    }

    /// The pass's row of the players asked whether the terrain lets them see an entity at this
    /// footprint, then of those it does; null past room for footprints.
    fn seenRow(self: *Tracking, world: u32, entry: Entry) ?[]u64 {
        const column = entities_module.space.columnOf(world, entry.position);
        return row: {
            const footprint = footprintOf(entry);
            const key: SeenKey = .{ .world = world, .x = column.x, .z = column.z, .footprint = footprint };
            if (self.seen_footprints.get(key)) |at| break :row self.seen_rows[at * 2 * self.words ..][0 .. 2 * self.words];
            if (self.seen_footprints.count() == shared_footprints) break :row null;
            const at = self.seen_count;
            self.seen_count += 1;
            self.seen_footprints.putAssumeCapacity(key, @intCast(at));
            const fresh = self.seen_rows[at * 2 * self.words ..][0 .. 2 * self.words];
            @memset(fresh, 0);
            break :row fresh;
        };
    }

    // Work.

    fn item(self: *const Tracking, index: u32) []u64 {
        const stride = 2 * self.words;
        return self.work_rows.run(@as(usize, index) * stride, @as(usize, index) * stride + stride).?;
    }

    /// The slot's entry in this tick's work, made if it has none; null once the work is full.
    fn workOf(self: *Tracking, slot: u32) !?[]u64 {
        const meta = self.metas.at(slot);
        if (meta.work != none) {
            const rows = self.item(meta.work);
            const open = self.work_open.at(meta.work);
            if (open.* == 0) {
                // Spawns and removals still owed become answers again: each owed pair, and what
                // it wants, for this pass to change.
                for (0..self.words) |word| {
                    const spawn = rows[word];
                    const remove = rows[self.words + word];
                    rows[word] = spawn | remove;
                    rows[self.words + word] = spawn;
                }
                open.* = 1;
                _ = try self.opened.append(meta.work);
            }
            return rows;
        }
        const rows = (try self.newWork(slot)) orelse return null;
        self.work_open.at(meta.work).* = 1;
        _ = try self.opened.append(meta.work);
        return rows;
    }

    /// An entry of the work for a slot, holding nothing.
    fn newWork(self: *Tracking, slot: u32) !?[]u64 {
        const meta = self.metas.at(slot);
        if (self.work_slots.len == self.config.work) {
            self.work_overflowed = true;
            return null;
        }
        const index = try self.work_slots.append(slot);
        _ = try self.work_trackers.append(meta.tracker);
        _ = try self.work_open.append(0);
        try self.work_rows.ensureFilled((index + 1) * 2 * self.words, 0);
        meta.work = @intCast(index);
        const rows = self.item(meta.work);
        @memset(rows, 0);
        return rows;
    }

    /// One player's answer for an entity, kept where it differs from what the client has.
    fn note(self: *Tracking, slot: u32, player: usize, wanted: bool) !void {
        const meta = self.metas.at(slot);
        if (meta.work == none) {
            if (has(self.knownWords(slot), player) == wanted) return;
        } else if (self.work_open.at(meta.work).* == 0) {
            // Owed already as it wants: a spawn owed wants it, a removal owed does not, and
            // with neither it wants what it has.
            const rows = self.item(meta.work);
            const owed = has(rows[0..self.words], player) or (has(self.knownWords(slot), player) and !has(rows[self.words..], player));
            if (owed == wanted) return;
        }
        self.stats.changed += 1;
        const rows = (try self.workOf(slot)) orelse return;
        put(rows[0..self.words], player, true);
        put(rows[self.words..], player, wanted);
    }

    /// What tracking keeps of the entity in a slot, made afresh for one it has not seen there.
    fn adoptSlot(self: *Tracking, slot: u32, entity: u64, tracker: u8) !*Meta {
        try self.ensureSlot(slot);
        const meta = self.metas.at(slot);
        if (meta.tracker == tracker and meta.entity == entity) return meta;
        // A slot let go and taken by another entity: nobody has the new one yet.
        assert(!any(self.knownWords(slot)));
        if (meta.work != none) {
            @memset(self.item(meta.work), 0);
            self.work_trackers.at(meta.work).* = tracker;
        }
        meta.* = .{ .tracker = tracker, .entity = entity, .looked = meta.looked, .work = meta.work };
        return meta;
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
        if (range > 0 and meta.range == 0) _ = try self.own_ranged.append(slot);
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

    // Tiles.

    fn tileKey(world: u32, x: i32, z: i32) u128 {
        const ux: u32 = @bitCast(x);
        const uz: u32 = @bitCast(z);
        return @as(u128, world) << 64 | @as(u128, ux) << 32 | uz;
    }

    fn tileHash(key: u128) u64 {
        const low: u64 = @truncate(key);
        const high: u64 = @truncate(key >> 64);
        const mixed = low *% 0x9e3779b97f4a7c15 ^ high *% 0xc2b2ae3d27d4eb4f;
        return mixed ^ (mixed >> 29);
    }

    fn tileBucketOf(self: *const Tracking, key: u128) usize {
        const mask = self.tile_buckets.len - 1;
        var at: usize = @as(usize, @truncate(tileHash(key))) & mask;
        while (true) : (at = (at + 1) & mask) {
            const bucket = self.tile_buckets.at(at);
            if (bucket.at == none or bucket.key == key) return at;
        }
    }

    fn findTile(self: *const Tracking, world: u32, x: i32, z: i32) ?u32 {
        const key = tileKey(world, x, z);
        // Most asked again at once, as the columns of a box or a player's walk share tiles.
        if (self.last_tile != none and self.last_tile_key == key) return self.last_tile;
        const bucket = self.tile_buckets.at(self.tileBucketOf(key));
        if (bucket.at == none) return null;
        const held = @constCast(self);
        held.last_tile = bucket.at;
        held.last_tile_key = key;
        return bucket.at;
    }

    /// The tile of a column, made with every player's answers if it had none.
    fn tileOf(self: *Tracking, world: u32, column_x: i32, column_z: i32) !u32 {
        const x = column_x >> 3;
        const z = column_z >> 3;
        if (self.findTile(world, x, z)) |found| return found;
        // A power of two, so no tile straddles a page.
        if (self.tile_stride == 0) self.tile_stride = try std.math.ceilPowerOfTwo(usize, tile_columns * self.group_count * 2 * self.words);
        if (self.tiles.count == self.config.tiles) try self.dropEmptyTiles();
        if (self.tiles.count == self.config.tiles) return error.TrackingTilesExhausted;
        self.tile_generation +%= 1;
        if (self.tile_generation == 0) self.tile_generation = 1;
        const index = try self.tiles.add(.{ .world = world, .x = x, .z = z, .generation = self.tile_generation });
        errdefer self.tiles.remove(index);
        try self.tile_masks.ensureFilled((@as(usize, index) + 1) * self.tile_stride, 0);
        @memset(self.tileMasks(index), 0);
        self.tile_buckets.at(self.tileBucketOf(tileKey(world, x, z))).* = .{ .key = tileKey(world, x, z), .at = index };
        self.stats.tiles_made += 1;
        for (0..self.deps.players.records.len) |player| {
            if (!self.anchored[player] or self.anchor_world[player] != world) continue;
            self.answerTile(index, player, self.anchor_x[player], self.anchor_z[player], self.anchor_reach[player]);
        }
        return index;
    }

    fn tileMasks(self: *const Tracking, tile: u32) []u64 {
        const start = @as(usize, tile) * self.tile_stride;
        return self.tile_masks.run(start, start + self.tile_stride).?;
    }

    /// A column's yes row and edge row of one range.
    fn masksOf(self: *const Tracking, tile: u32, column: usize, group: usize) struct { yes: []u64, edge: []u64 } {
        const start = @as(usize, tile) * self.tile_stride + (column * self.group_count + group) * 2 * self.words;
        const both = self.tile_masks.run(start, start + 2 * self.words).?;
        return .{ .yes = both[0..self.words], .edge = both[self.words..] };
    }

    fn classOf(self: *const Tracking, tile: u32, column: usize, group: usize, player: usize) Class {
        const masks = self.masksOf(tile, column, group);
        if (has(masks.yes, player)) return .yes;
        if (has(masks.edge, player)) return .edge;
        return .no;
    }

    fn setClass(self: *const Tracking, tile: u32, column: usize, group: usize, player: usize, class: Class) void {
        const masks = self.masksOf(tile, column, group);
        put(masks.yes, player, class == .yes);
        put(masks.edge, player, class == .edge);
    }

    /// How a square stands against a player at an anchor with a reach, wherever within its slack
    /// the player goes.
    fn classify(x: f64, z: f64, reach: f64, low_x: f64, low_z: f64, side: f64) Class {
        const near_x = @max(0, @max(low_x - x, x - (low_x + side)));
        const near_z = @max(0, @max(low_z - z, z - (low_z + side)));
        const far_x = @max(@abs(x - low_x), @abs(x - (low_x + side)));
        const far_z = @max(@abs(z - low_z), @abs(z - (low_z + side)));
        const outer = reach + slack;
        if (near_x * near_x + near_z * near_z > outer * outer) return .no;
        const inner = reach - slack;
        if (inner >= 0 and far_x * far_x + far_z * far_z <= inner * inner) return .yes;
        return .edge;
    }

    /// One range's reach for a player.
    fn reachOf(self: *const Tracking, group: usize, reach: f64) f64 {
        return @min(self.groups[group].range, reach);
    }

    /// A player's answers for every column of a tile, from an anchor.
    fn answerTile(self: *Tracking, tile: u32, player: usize, x: f64, z: f64, reach: f64) void {
        const held = self.tiles.at(tile);
        const low_x: f64 = @floatFromInt(held.x * tile_side * 16);
        const low_z: f64 = @floatFromInt(held.z * tile_side * 16);
        for (0..self.group_count) |group| {
            const group_reach = self.reachOf(group, reach);
            const whole = classify(x, z, group_reach, low_x, low_z, tile_side * 16);
            for (0..tile_columns) |column| {
                const class = if (whole != .edge) whole else classify(x, z, group_reach, low_x + @as(f64, @floatFromInt(column % tile_side)) * 16, low_z + @as(f64, @floatFromInt(column / tile_side)) * 16, 16);
                self.setClass(tile, column, group, player, class);
            }
        }
    }

    /// The space's index of a tile's column, if it is there still; the tile forgets it if not.
    fn spaceIndex(self: *Tracking, tile: u32, column: usize) ?u32 {
        const held = self.tiles.at(tile);
        const space = &self.deps.entities.places.space;
        const cached = held.index[column];
        if (cached != none and cached < space.columns.values.len and space.data(cached).made == held.made[column]) return cached;
        const at: Column = .{ .world = held.world, .x = held.x * tile_side + @as(i32, @intCast(column % tile_side)), .z = held.z * tile_side + @as(i32, @intCast(column / tile_side)) };
        const index = space.indexOf(at) orelse {
            held.index[column] = none;
            return null;
        };
        held.index[column] = index;
        held.made[column] = space.data(index).made;
        return index;
    }

    /// A column holds tracked entities or boxes: newly so, it joins the edge lists of the players
    /// at its edge.
    fn occupy(self: *Tracking, tile: u32, column: usize) !void {
        const held = self.tiles.at(tile);
        const bit = @as(u64, 1) << @intCast(column);
        if (held.occupied & bit != 0) return;
        held.occupied |= bit;
        for (0..self.group_count) |group| {
            const edge = self.masksOf(tile, column, group).edge;
            for (edge, 0..) |word, at| {
                var bits = word;
                while (bits != 0) : (bits &= bits - 1) _ = try self.edges[at * 64 + @ctz(bits)].append(.{ .tile = tile, .generation = held.generation, .column = @intCast(column), .group = @intCast(group) });
            }
        }
    }

    /// Tiles holding nothing tracked go, to make room.
    fn dropEmptyTiles(self: *Tracking) !void {
        for (0..self.tiles.values.len) |index| {
            const tile: u32 = @intCast(index);
            const held = self.tiles.at(tile);
            if (held.generation == 0) continue;
            var occupied = held.occupied;
            while (occupied != 0) : (occupied &= occupied - 1) {
                const column = @ctz(occupied);
                if (self.spaceIndex(tile, column) == null) held.occupied &= ~(@as(u64, 1) << @intCast(column));
            }
            if (held.occupied != 0) continue;
            self.unhashTile(tileKey(held.world, held.x, held.z));
            self.tiles.remove(tile);
            self.tiles.at(tile).generation = 0;
        }
    }

    fn unhashTile(self: *Tracking, key: u128) void {
        if (self.last_tile_key == key) self.last_tile = none;
        const mask = self.tile_buckets.len - 1;
        var hole = self.tileBucketOf(key);
        var at = hole;
        while (true) {
            at = (at + 1) & mask;
            const bucket = self.tile_buckets.at(at);
            if (bucket.at == none) break;
            const home = @as(usize, @truncate(tileHash(bucket.key))) & mask;
            const stays = if (hole <= at) (home > hole and home <= at) else (home > hole or home <= at);
            if (stays) continue;
            self.tile_buckets.at(hole).* = bucket.*;
            hole = at;
        }
        self.tile_buckets.at(hole).* = .{};
    }

    // Answers for one player.

    /// An entity's answer for one player whose distance test is known: what it says of itself and
    /// the terrain asked only where it is within reach.
    fn consider(self: *Tracking, slot: u32, entry: Entry, world: u32, player: usize, within: bool) !void {
        if (!within) {
            self.stats.asked += 1;
            if (slot < self.metas.len and (self.metas.at(slot).work != none or has(self.knownWords(slot), player))) try self.note(slot, player, false);
            return;
        }
        const tracker = self.tracker_of[entry.shape.kind];
        if (tracker == no_tracker) return;
        const meta = try self.adoptSlot(slot, entry.id, tracker);
        return self.considerAdopted(meta, slot, entry, world, player, within);
    }

    /// `consider`, for an entity whose tracking data is in hand.
    fn considerAdopted(self: *Tracking, meta: *const Meta, slot: u32, entry: Entry, world: u32, player: usize, within: bool) !void {
        self.stats.asked += 1;
        if (!within) {
            if (meta.work != none or has(self.knownWords(slot), player)) try self.note(slot, player, false);
            return;
        }
        if (meta.gone) return;
        const wanted = self.ready[player] and self.worlds[player] == world and self.admits(meta, slot, player) and self.terrainLets(world, entry, player);
        try self.note(slot, player, wanted);
    }

    fn perPlayer(comptime T: type, allocator: std.mem.Allocator, count: usize, each: usize) ![][]T {
        const lists = try allocator.alloc([]T, count);
        for (lists) |*list| list.* = try allocator.alloc(T, each);
        return lists;
    }

    /// Near entities eight at a time, each part side by side.
    const near_lanes = 8;
    const NearChunk = struct {
        x: [near_lanes]f64,
        z: [near_lanes]f64,
        reach: [near_lanes]f64,
        slot: [near_lanes]u32,
        within: [near_lanes]u8,
    };

    /// How near its reach an edge entity must be, when a player last measured, to be measured each
    /// time the player moves; the player measures everything again once it moved that far.
    pub const near_band = 2.0;
    /// Near entities and boxes a player keeps at most.
    const near_max = 512;
    const near_boxes_max = 64;

    fn resetNear(self: *Tracking, player: usize) void {
        self.near_count[player] = 0;
        self.near_box_count[player] = 0;
        self.near_full[player] = false;
    }

    /// An entity near a player's reach, measured each time it moves. One that moved is added
    /// again; past twice what was gathered, they are gathered afresh.
    fn addNear(self: *Tracking, player: usize, x: f64, z: f64, squared: f64, slot: u32, within: bool) !void {
        if (self.near_full[player]) return;
        const at = self.near_count[player];
        if (at == near_max or at >= 2 * self.near_gathered[player] + 64) {
            self.near_full[player] = true;
            return;
        }
        const chunk = &self.near_chunks[player][at / near_lanes];
        const lane = at % near_lanes;
        chunk.x[lane] = x;
        chunk.z[lane] = z;
        chunk.reach[lane] = squared;
        chunk.slot[lane] = slot;
        chunk.within[lane] = @intFromBool(within);
        self.near_count[player] = at + 1;
    }

    fn addNearBox(self: *Tracking, player: usize, slot: u32) !void {
        if (self.near_full[player]) return;
        const at = self.near_box_count[player];
        if (at == near_boxes_max) {
            self.near_full[player] = true;
            return;
        }
        self.near_boxes[player][at] = slot;
        self.near_box_count[player] = at + 1;
    }

    /// Whether an entity a player just answered at `squared` distance of a reach is near enough
    /// the reach, as the player last measured, to be measured each time it moves.
    fn nearReach(self: *const Tracking, player: usize, squared: f64, reach: f64) bool {
        const dx = self.xs[player] - self.measure_x[player];
        const dz = self.zs[player] - self.measure_z[player];
        const band = near_band + @sqrt(dx * dx + dz * dz);
        const inner = @max(0, reach - band);
        const outer = reach + band;
        return squared > inner * inner and squared < outer * outer;
    }

    /// A player's near entities measured where it is: those that went across their reach since
    /// last measured are answered again, and the near boxes.
    fn nearTest(self: *Tracking, player: usize) !void {
        const space = &self.deps.entities.places.space;
        const count = self.near_count[player];
        self.stats.near_measured += count;
        const V = @Vector(near_lanes, f64);
        const px: V = @splat(self.xs[player]);
        const pz: V = @splat(self.zs[player]);
        for (self.near_chunks[player][0 .. (count + near_lanes - 1) / near_lanes], 0..) |*chunk, index| {
            const width = @min(near_lanes, count - index * near_lanes);
            const dx = @as(V, chunk.x) - px;
            const dz = @as(V, chunk.z) - pz;
            const within: u8 = @bitCast(dx * dx + dz * dz <= @as(V, chunk.reach));
            const was: u8 = @bitCast(@as(@Vector(near_lanes, u8), chunk.within) != @as(@Vector(near_lanes, u8), @splat(0)));
            var picked: u8 = (within ^ was) & @as(u8, @truncate((@as(u16, 1) << @intCast(width)) - 1));
            while (picked != 0) : (picked &= picked - 1) {
                const lane = @ctz(picked);
                chunk.within[lane] = @intFromBool(within & (@as(u8, 1) << @intCast(lane)) != 0);
                const slot = chunk.slot[lane];
                // Where it is now, which a near entry made before it moved again may not say.
                if (space.boxOf(slot)) |boxed| {
                    try self.boxFor(space.box_of[slot], boxed, player);
                    continue;
                }
                const placed = space.atSlot(slot) orelse continue;
                // One with its own range is asked of every player each pass anyway.
                if (slot < self.metas.len and self.metas.at(slot).range > 0) continue;
                const ex = placed.entry.position[0] - self.xs[player];
                const ez = placed.entry.position[2] - self.zs[player];
                try self.consider(slot, placed.entry, placed.world, player, ex * ex + ez * ez <= chunk.reach[lane]);
            }
        }
        for (self.near_boxes[player][0..self.near_box_count[player]]) |slot| {
            const boxed = space.boxOf(slot) orelse continue;
            try self.boxFor(space.box_of[slot], boxed, player);
        }
    }

    /// The entities of one range in a column, for one player: every one measured from where it
    /// stands now, or, with `from`, only those the move from there to here took across its reach.
    /// With `collect`, those near its reach join its near entities.
    fn columnFor(self: *Tracking, tile: u32, column: usize, group: usize, player: usize, from: ?[2]f64, collect: bool) !void {
        const index = self.spaceIndex(tile, column) orelse {
            self.tiles.at(tile).occupied &= ~(@as(u64, 1) << @intCast(column));
            return;
        };
        self.stats.columns += 1;
        const space = &self.deps.entities.places.space;
        const world = self.tiles.at(tile).world;
        const reach = self.reachOf(group, self.reaches[player]);
        const squared = reach * reach;
        const x = self.xs[player];
        const z = self.zs[player];
        const lanes = 8;
        const V = @Vector(lanes, f64);
        var runs = space.runsAt(index, self.groups[group].kinds);
        while (runs.next()) |run| {
            var at = run.first;
            while (at != entities_module.space.none) {
                const block = space.blockAt(at);
                at = block.next;
                self.stats.measured += block.count;
                var start: usize = 0;
                while (start < block.count) : (start += lanes) {
                    // Rows past the count are measured and passed over.
                    const bx: V = block.x[start..][0..lanes].*;
                    const bz: V = block.z[start..][0..lanes].*;
                    const dx = bx - @as(V, @splat(x));
                    const dz = bz - @as(V, @splat(z));
                    const now: @Vector(lanes, bool) = dx * dx + dz * dz <= @as(V, @splat(squared));
                    var picked: u8 = if (from) |was| picked: {
                        const ex = bx - @as(V, @splat(was[0]));
                        const ez = bz - @as(V, @splat(was[1]));
                        const then: @Vector(lanes, bool) = ex * ex + ez * ez <= @as(V, @splat(squared));
                        break :picked @bitCast(now != then);
                    } else 0xff;
                    const live: u8 = if (block.count - start >= lanes) 0xff else @truncate((@as(u16, 1) << @intCast(block.count - start)) - 1);
                    picked &= live;
                    const within: u8 = @bitCast(now);
                    if (collect) {
                        const squares = dx * dx + dz * dz;
                        const inner = @max(0, reach - near_band);
                        const outer = reach + near_band;
                        var close: u8 = @as(u8, @bitCast(squares > @as(V, @splat(inner * inner)))) & @as(u8, @bitCast(squares < @as(V, @splat(outer * outer))));
                        close &= live;
                        while (close != 0) : (close &= close - 1) {
                            const lane = @ctz(close);
                            const row = start + lane;
                            try self.addNear(player, block.x[row], block.z[row], squared, block.slot[row], within & (@as(u8, 1) << @intCast(lane)) != 0);
                        }
                    }
                    while (picked != 0) : (picked &= picked - 1) {
                        const lane = @ctz(picked);
                        const row: u32 = @intCast(start + lane);
                        const entry: Entry = .{
                            .id = block.id[row],
                            .slot = block.slot[row],
                            .section = entities_module.space.coordinate(block.y[row]),
                            .entered = block.entered[row],
                            .position = block.position(row),
                            .shape = .{ .kind = run.kind, .half_width = block.half_width[row], .height = block.height[row] },
                        };
                        try self.consider(entry.slot, entry, world, player, within & (@as(u8, 1) << @intCast(lane)) != 0);
                    }
                }
            }
        }
        var boxes = space.boxesAt(index);
        while (boxes.next()) |box| {
            const boxed = space.boxAt(box);
            if (!self.groups[group].kinds.has(boxed.kind)) continue;
            if (collect) try self.addNearBox(player, boxed.slot);
            try self.boxFor(box, boxed, player);
        }
    }

    /// A box answered for one player, once a pass whatever columns it is met in.
    fn boxFor(self: *Tracking, index: u32, boxed: *const Boxed, player: usize) !void {
        try self.box_stamps.ensureFilled(@as(usize, index) + 1, 0);
        const stamp = self.tick_count << 16 | player;
        if (self.box_stamps.at(index).* == stamp) return;
        self.box_stamps.at(index).* = stamp;
        const tracker = self.tracker_of[boxed.kind];
        if (tracker == no_tracker) return;
        const meta = try self.adoptSlot(boxed.slot, self.deps.entities.directory.entry(boxed.slot).id, tracker);
        if (meta.gone) return;
        self.stats.boxes += 1;
        const wanted = switch (self.boxAnswer(boxed.slot, boxed.world, boxed.feet, boxed.reach(), self.rangeOf(&self.trackers[tracker], boxed.slot), player)) {
            .no => false,
            .yes => true,
            .unsure => wanted: {
                try self.unsettle(boxed.slot);
                const placed = try self.exactOf(tracker, boxed);
                break :wanted self.sees(boxed.slot, placed.entry, placed.world, self.rangeOf(&self.trackers[tracker], boxed.slot), player);
            },
        };
        try self.note(boxed.slot, player, wanted);
    }

    // Players.

    /// The tiles a player's answers can be other than no in, around a point.
    fn tileSpan(self: *const Tracking, x: f64, z: f64, reach: f64) [2][2]i32 {
        var widest: f64 = 0;
        for (self.groups[0..self.group_count]) |group| widest = @max(widest, @min(group.range, reach));
        const out = widest + slack + 1;
        return .{
            .{ @as(i32, @intFromFloat(@floor((x - out) / 16))) >> 3, @as(i32, @intFromFloat(@floor((x + out) / 16))) >> 3 },
            .{ @as(i32, @intFromFloat(@floor((z - out) / 16))) >> 3, @as(i32, @intFromFloat(@floor((z + out) / 16))) >> 3 },
        };
    }

    /// A player anchored where it is: every column whose answer changes, and every edge column,
    /// has its entities answered for the player again; its edge list is made afresh.
    fn anchor(self: *Tracking, player: usize) !void {
        self.stats.anchored += 1;
        const was_anchored = self.anchored[player];
        const old_world = self.anchor_world[player];
        const old_x = self.anchor_x[player];
        const old_z = self.anchor_z[player];
        const old_reach = self.anchor_reach[player];
        const world = self.worlds[player];
        const x = self.xs[player];
        const z = self.zs[player];
        const reach = self.reaches[player];
        // Its near entities brought up to where it is first, so each edge column measured from
        // where it last measured answers for all of them; then gathered afresh.
        if (was_anchored) try self.nearTest(player);
        const from: [2]f64 = .{ self.measure_x[player], self.measure_z[player] };
        self.resetNear(player);
        defer self.near_gathered[player] = self.near_count[player];
        self.measure_x[player] = x;
        self.measure_z[player] = z;
        self.anchored[player] = true;
        self.anchor_world[player] = world;
        self.anchor_x[player] = x;
        self.anchor_z[player] = z;
        self.anchor_reach[player] = reach;
        self.edges[player].reset();
        const now = self.tileSpan(x, z, reach);
        var tx = now[0][0];
        while (tx <= now[0][1]) : (tx += 1) {
            var tz = now[1][0];
            while (tz <= now[1][1]) : (tz += 1) {
                const tile = self.findTile(world, tx, tz) orelse continue;
                try self.reanswerTile(tile, player, was_anchored and old_world == world, old_x, old_z, old_reach, x, z, reach, from);
            }
        }
        // Tiles around where it was and not around where it is: only answers going to no.
        if (!was_anchored) return;
        const then = self.tileSpan(old_x, old_z, old_reach);
        tx = then[0][0];
        while (tx <= then[0][1]) : (tx += 1) {
            var tz = then[1][0];
            while (tz <= then[1][1]) : (tz += 1) {
                if (old_world == world and tx >= now[0][0] and tx <= now[0][1] and tz >= now[1][0] and tz <= now[1][1]) continue;
                const tile = self.findTile(old_world, tx, tz) orelse continue;
                try self.reanswerTile(tile, player, true, old_x, old_z, old_reach, x, z, reach, from);
            }
        }
    }

    /// A player's answers for a tile from a new anchor: columns whose answer changed, or that are
    /// at its edge, have their entities answered again.
    fn reanswerTile(self: *Tracking, tile: u32, player: usize, had: bool, old_x: f64, old_z: f64, old_reach: f64, x: f64, z: f64, reach: f64, from: [2]f64) !void {
        const held = self.tiles.at(tile);
        const in_world = self.ready[player] and held.world == self.worlds[player];
        const low_x: f64 = @floatFromInt(held.x * tile_side * 16);
        const low_z: f64 = @floatFromInt(held.z * tile_side * 16);
        for (0..self.group_count) |group| {
            const old_whole: Class = if (had) classify(old_x, old_z, self.reachOf(group, old_reach), low_x, low_z, tile_side * 16) else .no;
            const new_whole: Class = if (in_world) classify(x, z, self.reachOf(group, reach), low_x, low_z, tile_side * 16) else .no;
            if (old_whole == new_whole and old_whole != .edge) continue;
            for (0..tile_columns) |column| {
                const column_x = low_x + @as(f64, @floatFromInt(column % tile_side)) * 16;
                const column_z = low_z + @as(f64, @floatFromInt(column / tile_side)) * 16;
                const old: Class = if (old_whole != .edge) old_whole else classify(old_x, old_z, self.reachOf(group, old_reach), column_x, column_z, 16);
                const new: Class = if (new_whole != .edge) new_whole else classify(x, z, self.reachOf(group, reach), column_x, column_z, 16);
                if (old != new) self.setClass(tile, column, group, player, new);
                if (self.tiles.at(tile).occupied & (@as(u64, 1) << @intCast(column)) == 0) continue;
                if (old == new and new != .edge) continue;
                if (new == .edge) _ = try self.edges[player].append(.{ .tile = tile, .generation = held.generation, .column = @intCast(column), .group = @intCast(group) });
                // An edge column it was at the edge of before answers as last measured; any other
                // is measured whole.
                try self.columnFor(tile, column, group, player, if (old == .edge and new == .edge and reach == old_reach) from else null, new == .edge);
            }
        }
    }

    /// A player that moved within its slack: its near entities measured, or, once it went that
    /// far from where it last measured, or its near entities did not fit, every entity of its
    /// edge columns it went across the reach of, and its near entities gathered afresh.
    fn slackMove(self: *Tracking, player: usize) !void {
        self.stats.slack_moves += 1;
        const mx = self.xs[player] - self.measure_x[player];
        const mz = self.zs[player] - self.measure_z[player];
        if (!self.near_full[player] and mx * mx + mz * mz < near_band * near_band) return self.nearTest(player);
        try self.nearTest(player);
        self.stats.edge_walks += 1;
        const from: [2]f64 = .{ self.measure_x[player], self.measure_z[player] };
        self.resetNear(player);
        self.measure_x[player] = self.xs[player];
        self.measure_z[player] = self.zs[player];
        const list = &self.edges[player];
        var at: usize = 0;
        while (at < list.len) : (at += 1) {
            const edge = list.at(at).*;
            const held = self.tiles.at(edge.tile);
            if (held.generation != edge.generation or held.occupied & (@as(u64, 1) << @intCast(edge.column)) == 0) continue;
            if (self.classOf(edge.tile, edge.column, edge.group, player) != .edge) continue;
            try self.columnFor(edge.tile, edge.column, edge.group, player, from, true);
        }
        self.near_gathered[player] = self.near_count[player];
    }

    /// A player's answers taken away: its bits cleared in every tile around its anchor.
    fn unanchor(self: *Tracking, player: usize) void {
        // What was owed it from before is owed no more: whatever it is owed now is asked anew.
        for (0..self.work_slots.len) |index| {
            const rows = self.item(@intCast(index));
            put(rows[0..self.words], player, false);
            put(rows[self.words..], player, false);
        }
        if (!self.anchored[player]) return;
        self.anchored[player] = false;
        self.edges[player].reset();
        self.resetNear(player);
        const span = self.tileSpan(self.anchor_x[player], self.anchor_z[player], self.anchor_reach[player]);
        var tx = span[0][0];
        while (tx <= span[0][1]) : (tx += 1) {
            var tz = span[1][0];
            while (tz <= span[1][1]) : (tz += 1) {
                const tile = self.findTile(self.anchor_world[player], tx, tz) orelse continue;
                for (0..tile_columns) |column| for (0..self.group_count) |group| self.setClass(tile, column, group, player, .no);
            }
        }
    }

    /// What a player was shown around where it was: forgotten, as its client forgot it; told gone,
    /// as it stopped being ready; or asked about again, as its mode changed and it may have moved.
    const Near = enum { forget, drop, recheck };

    fn near(self: *Tracking, player: usize, was: PlayerChanges.Snapshot, mode: Near) !void {
        const space = &self.deps.entities.places.space;
        const span = self.tileSpan(was.x, was.z, was.reach);
        var tx = span[0][0];
        while (tx <= span[0][1]) : (tx += 1) {
            var tz = span[1][0];
            while (tz <= span[1][1]) : (tz += 1) {
                const tile = self.findTile(was.world, tx, tz) orelse continue;
                var occupied = self.tiles.at(tile).occupied;
                while (occupied != 0) : (occupied &= occupied - 1) {
                    const index = self.spaceIndex(tile, @ctz(occupied)) orelse continue;
                    var walk = space.entriesAt(index, self.tracked);
                    while (walk.next()) |entry| try self.nearPair(entry.slot, player, mode);
                    var boxes = space.boxesAt(index);
                    while (boxes.next()) |box| try self.nearPair(space.boxAt(box).slot, player, mode);
                }
            }
        }
        // And those it may have farther off: gone, offered last tick and not taken, moved since,
        // or with ranges of their own.
        for ([_]*Array(u32){ &self.gone, &self.retry, &self.own_ranged }) |list| {
            var at: usize = 0;
            while (at < list.len) : (at += 1) try self.nearPair(list.at(at).*, player, mode);
        }
        const log = space.logged();
        var at: usize = 0;
        while (at < log.len) : (at += 1) try self.nearPair(log.at(at).slot, player, mode);
        if (space.log_overflowed) for (0..self.metas.len) |slot| try self.nearPair(@intCast(slot), player, mode);
    }

    fn nearPair(self: *Tracking, slot: u32, player: usize, mode: Near) !void {
        if (mode == .recheck) return self.recheckPair(slot, player);
        if (slot >= self.metas.len) return;
        switch (mode) {
            .forget => self.forgetPair(slot, player),
            .drop => if (has(self.knownWords(slot), player)) try self.note(slot, player, false),
            .recheck => try self.recheckPair(slot, player),
        }
    }

    /// An entity answered for one player where it is now, every part of the rule asked.
    fn recheckPair(self: *Tracking, slot: u32, player: usize) !void {
        const space = &self.deps.entities.places.space;
        if (space.boxOf(slot)) |boxed| return self.boxFor(space.box_of[slot], boxed, player);
        const placed = space.atSlot(slot) orelse return;
        const tracker = self.tracker_of[placed.entry.shape.kind];
        if (tracker == no_tracker) return;
        const reach = @min(self.rangeOf(&self.trackers[tracker], slot), self.reaches[player]);
        const dx = self.xs[player] - placed.entry.position[0];
        const dz = self.zs[player] - placed.entry.position[2];
        try self.consider(slot, placed.entry, placed.world, player, self.ready[player] and self.worlds[player] == placed.world and dx * dx + dz * dz <= reach * reach);
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
            if (meta.work != none) self.work_trackers.at(meta.work).* = no_tracker;
            meta.* = .{ .looked = meta.looked, .work = meta.work };
        }
    }

    // Entities.

    /// Asks again about one entity by its slot, as it stands now; `fresh` when what it said of
    /// itself or its last answer may be stale, so every player near is asked.
    fn look(self: *Tracking, slot: u32, fresh: bool) !void {
        const directory = &self.deps.entities.directory;
        if (slot >= directory.high()) return;
        const space = &self.deps.entities.places.space;
        if (space.boxOf(slot)) |boxed| return self.checkBox(slot, boxed);
        if (space.atSlot(slot)) |placed| return self.checkPoint(placed.entry, placed.world, fresh);
        // Gone from the space: whoever has it is told.
        if (slot >= self.metas.len) return;
        const meta = self.metas.at(slot);
        if (meta.tracker == no_tracker) return;
        meta.looked = self.tick_count;
        meta.placed = false;
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

    /// An entity at a point, answered from its column's masks: when it stays in its column and
    /// footprint, only players at the column's edge are measured; else every player the column is
    /// not a no for is asked.
    fn checkPoint(self: *Tracking, entry: Entry, world: u32, fresh: bool) !void {
        const slot = entry.slot;
        const tracker = self.tracker_of[entry.shape.kind];
        if (tracker == no_tracker) return;
        const meta = try self.adoptSlot(slot, entry.id, tracker);
        meta.gone = false;
        meta.looked = self.tick_count;
        meta.settled_for = 0;
        // One with its own range is asked of every player each pass.
        if (meta.range > 0) return self.checkEveryone(entry, world);
        const column = entities_module.space.columnOf(world, entry.position);
        const footprint = footprintOf(entry);
        const same_column = meta.placed and meta.world == world and meta.column[0] == column.x and meta.column[1] == column.z;
        const same = !fresh and same_column and std.meta.eql(meta.footprint, footprint);
        const kept = same_column and meta.tile != none and self.tiles.at(meta.tile).generation == meta.tile_generation;
        meta.placed = true;
        meta.world = world;
        meta.column = .{ column.x, column.z };
        meta.footprint = footprint;
        const tile = if (kept) meta.tile else try self.tileOf(world, column.x, column.z);
        meta.tile = tile;
        meta.tile_generation = self.tiles.at(tile).generation;
        const index: usize = @intCast((column.x & 7) + (column.z & 7) * tile_side);
        try self.occupy(tile, index);
        const masks = self.masksOf(tile, index, self.trackers[tracker].group);
        const known_words = self.knownWords(slot);
        // Those who have it and whom the column is a no for are told it is gone.
        var quiet = true;
        for (known_words, masks.yes, masks.edge, 0..) |have, yes, edge, word| {
            var gone = have & ~(yes | edge);
            if (gone != 0) quiet = false;
            while (gone != 0) : (gone &= gone - 1) try self.note(slot, word * 64 + @ctz(gone), false);
        }
        // Players the column is a yes for are within reach wherever they are: moved within its
        // column and footprint, the rest of their answer is the same as it was. Those at its edge
        // are measured. Each is answered a word at a time.
        const reach = self.trackers[tracker].range;
        const asked = self.scratch[0..self.words];
        const within = self.scratch[self.words..][0..self.words];
        for (masks.yes, masks.edge, asked, within, 0..) |yes, edge, *ask, *in, word| {
            ask.* = (if (same) 0 else yes) | edge;
            in.* = if (same) 0 else yes;
            var measured = edge;
            while (measured != 0) : (measured &= measured - 1) {
                const player = word * 64 + @ctz(measured);
                const player_reach = @min(reach, self.reaches[player]);
                const dx = self.xs[player] - entry.position[0];
                const dz = self.zs[player] - entry.position[2];
                const squared = dx * dx + dz * dz;
                const close = squared <= player_reach * player_reach;
                if (close) in.* |= @as(u64, 1) << @intCast(player % 64);
                // Near its reach, it is measured as the player moves.
                if (self.anchored[player] and self.nearReach(player, squared, player_reach)) try self.addNear(player, entry.position[0], entry.position[2], player_reach * player_reach, slot, close);
            }
        }
        if (any(asked)) {
            quiet = false;
            try self.answerWords(meta, slot, entry, world, asked, within);
        }
        if (quiet) self.stats.logged_quiet += 1;
    }

    /// An entity answered for the players asked, a word at a time: those within reach who the
    /// terrain lets see it and it lets see it want it, the rest asked do not; only those whose
    /// answer differs from what they have or are owed are noted.
    fn answerWords(self: *Tracking, meta: *const Meta, slot: u32, entry: Entry, world: u32, asked: []const u64, within: []u64) !void {
        self.stats.asked += popCount(asked);
        // Who of those within reach the terrain lets see it, a footprint at once.
        if (any(within) and !meta.gone) {
            if (self.deps.streaming == null) {} else if (self.seenRow(world, entry)) |both| {
                const checked = both[0..self.words];
                const seen = both[self.words..];
                for (within, checked, seen, 0..) |*in, *done, *sees_it, word| {
                    var unknown = in.* & ~done.*;
                    while (unknown != 0) : (unknown &= unknown - 1) {
                        const player = word * 64 + @ctz(unknown);
                        if (self.terrainAnswer(world, entry, player)) sees_it.* |= @as(u64, 1) << @intCast(player % 64);
                    }
                    done.* |= in.*;
                    in.* &= sees_it.*;
                }
            } else for (within, 0..) |*in, word| {
                var unknown = in.*;
                while (unknown != 0) : (unknown &= unknown - 1) {
                    const player = word * 64 + @ctz(unknown);
                    if (!self.terrainAnswer(world, entry, player)) in.* &= ~(@as(u64, 1) << @intCast(player % 64));
                }
            }
            // What it says of itself.
            if (meta.owner != no_owner) put(within, meta.owner, false);
            if (meta.spectators_only) for (within, 0..) |*in, player_word| {
                in.* &= self.spectatingWord(player_word);
            };
            if (meta.restricted) for (within, self.allowedWords(slot)) |*in, allowed| {
                in.* &= allowed;
            };
        } else @memset(within, 0);
        const known_words = self.knownWords(slot);
        const rows: ?[]u64 = if (meta.work != none) self.item(meta.work) else null;
        const open = if (meta.work != none) self.work_open.at(meta.work).* != 0 else false;
        for (asked, within, known_words, 0..) |ask, want, have, word| {
            // What the client has or is owed now, as `note` reads it.
            const current = if (rows) |both| (if (open) (both[self.words + word] & both[word]) | (have & ~both[word]) else both[word] | (have & ~both[self.words + word])) else have;
            var differ = (want ^ current) & ask;
            while (differ != 0) : (differ &= differ - 1) {
                const bit = @ctz(differ);
                try self.note(slot, word * 64 + bit, want & (@as(u64, 1) << @intCast(bit)) != 0);
            }
        }
    }

    fn popCount(words: []const u64) u64 {
        var total: u64 = 0;
        for (words) |word| total += @popCount(word);
        return total;
    }

    /// A word of the players in spectator mode.
    fn spectatingWord(self: *const Tracking, word: usize) u64 {
        var bits: u64 = 0;
        const first = word * 64;
        for (self.spectating[first..@min(first + 64, self.spectating.len)], 0..) |spectator, at| {
            if (spectator) bits |= @as(u64, 1) << @intCast(at);
        }
        return bits;
    }

    /// An entity asked of every player in its world, by its own range.
    fn checkEveryone(self: *Tracking, entry: Entry, world: u32) !void {
        const range = self.rangeOf(&self.trackers[self.tracker_of[entry.shape.kind]], entry.slot);
        for (0..self.deps.players.records.len) |player| {
            const reach = @min(range, self.reaches[player]);
            const dx = self.xs[player] - entry.position[0];
            const dz = self.zs[player] - entry.position[2];
            try self.consider(entry.slot, entry, world, player, self.ready[player] and self.worlds[player] == world and dx * dx + dz * dz <= reach * reach);
        }
    }

    // Boxes.

    /// One player's answer for an entity anywhere in a box: where its feet may be, and its box
    /// anywhere along.
    fn boxAnswer(self: *const Tracking, slot: u32, world: u32, feet: Feet, reach_box: Feet, range: f64, player: usize) Answer {
        if (!self.ready[player] or self.worlds[player] != world) return .no;
        const meta = self.metas.at(slot);
        if (!self.admits(meta, slot, player)) return .no;
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
    fn distanceAnswer(feet: Feet, x: f64, z: f64, reach: f64) Answer {
        const near_x = @max(0, @max(feet.low[0] - x, x - feet.high[0]));
        const near_z = @max(0, @max(feet.low[2] - z, z - feet.high[2]));
        const far_x = @max(@abs(x - feet.low[0]), @abs(x - feet.high[0]));
        const far_z = @max(@abs(z - feet.low[2]), @abs(z - feet.high[2]));
        const squared = reach * reach;
        if (near_x * near_x + near_z * near_z > squared) return .no;
        if (far_x * far_x + far_z * far_z <= squared) return .yes;
        return .unsure;
    }

    /// Where a boxed entity is now, as its kind says, which must be in its box.
    fn exactOf(self: *Tracking, tracker: u8, boxed: *const Boxed) !Placed {
        self.stats.exact += 1;
        const exact = self.trackers[tracker].exact orelse return error.BoxWithoutExactPlace;
        const placed = try exact.place(exact.context, boxed.slot);
        assert(placed.world == boxed.world and boxed.feet.contains(placed.entry.position));
        return placed;
    }

    /// The players a box can be other than a no for: those its columns are not a no for, of the
    /// range of its kind. Their tiles are made.
    fn boxCandidates(self: *Tracking, world: u32, reach_box: Feet, group: usize, candidates: []u64, edges: ?[]u64) !void {
        var x = entities_module.space.coordinate(reach_box.low[0]);
        while (x <= entities_module.space.coordinate(reach_box.high[0])) : (x += 1) {
            var z = entities_module.space.coordinate(reach_box.low[2]);
            while (z <= entities_module.space.coordinate(reach_box.high[2])) : (z += 1) {
                const tile = try self.tileOf(world, x, z);
                const index: usize = @intCast((x & 7) + (z & 7) * tile_side);
                const masks = self.masksOf(tile, index, group);
                for (candidates, masks.yes, masks.edge) |*word, yes, edge| word.* |= yes | edge;
                if (edges) |row| for (row, masks.edge) |*word, edge| {
                    word.* |= edge;
                };
            }
        }
    }

    /// A boxed entity checked against every player who could see it anywhere in its box and every
    /// one who has it.
    fn checkBox(self: *Tracking, slot: u32, boxed: *const Boxed) !void {
        const tracker = self.tracker_of[boxed.kind];
        if (tracker == no_tracker) return;
        // Placed again in the columns it was in, which hold it already, and answered for this
        // very box as its kind asked this tick: nothing is left to do.
        if (boxed.in_place and slot < self.metas.len) {
            const meta = self.metas.at(slot);
            if (meta.tracker == tracker and meta.settled_for == self.tick_count and meta.settled_heard == self.heard_count and meta.work == none and std.meta.eql(meta.settled_box, boxed.feet)) {
                meta.gone = false;
                meta.placed = false;
                meta.looked = self.tick_count;
                return;
            }
        }
        const meta = try self.adoptSlot(slot, self.deps.entities.directory.entry(slot).id, tracker);
        meta.gone = false;
        meta.placed = false;
        meta.looked = self.tick_count;
        // The box's columns hold it, for the walks of players.
        const reach_box = boxed.reach();
        var x = entities_module.space.coordinate(reach_box.low[0]);
        while (x <= entities_module.space.coordinate(reach_box.high[0])) : (x += 1) {
            var z = entities_module.space.coordinate(reach_box.low[2]);
            while (z <= entities_module.space.coordinate(reach_box.high[2])) : (z += 1) {
                try self.occupy(try self.tileOf(boxed.world, x, z), @intCast((x & 7) + (z & 7) * tile_side));
            }
        }
        // Answered for this very box this pass already, as players stood: what they did since
        // their walks ask about.
        if (meta.settled_for == self.tick_count and meta.settled_heard == self.heard_count and meta.work == none and std.meta.eql(meta.settled_box, boxed.feet)) return;
        const candidates = self.scratch[0..self.words];
        @memcpy(candidates, self.knownWords(slot));
        const edges = self.scratch[2 * self.words ..][0..self.words];
        @memset(edges, 0);
        try self.boxCandidates(boxed.world, reach_box, self.trackers[tracker].group, candidates, edges);
        // Players at the edge of its columns answer it as they move.
        for (edges, 0..) |word, at| {
            var bits = word;
            while (bits != 0) : (bits &= bits - 1) {
                const player = at * 64 + @ctz(bits);
                if (self.anchored[player]) try self.addNearBox(player, slot);
            }
        }
        var exact: ?Placed = null;
        const range = self.rangeOf(&self.trackers[tracker], slot);
        for (candidates, 0..) |word, at| {
            var bits = word;
            while (bits != 0) : (bits &= bits - 1) {
                const player = at * 64 + @ctz(bits);
                self.stats.boxes += 1;
                const wanted = switch (self.boxAnswer(slot, boxed.world, boxed.feet, reach_box, range, player)) {
                    .no => false,
                    .yes => true,
                    .unsure => wanted: {
                        try self.unsettle(slot);
                        if (exact == null) exact = try self.exactOf(tracker, boxed);
                        break :wanted self.sees(slot, exact.?.entry, exact.?.world, range, player);
                    },
                };
                try self.note(slot, player, wanted);
            }
        }
    }

    fn unsettle(self: *Tracking, slot: u32) !void {
        const meta = self.metas.at(slot);
        if (meta.unsettled == self.tick_count) return;
        meta.unsettled = self.tick_count;
        _ = try self.unsettled.append(slot);
    }

    /// Whether an entity anywhere in a box, until its kind places it again, is seen by every
    /// player as clients have it now: none unsure, none to spawn or remove. What a kind asks before
    /// boxing one.
    pub fn settled(self: *Tracking, slot: u32, world: u32, feet: Feet, half_width: f32, height: f32) !bool {
        const meta = try self.subject(slot);
        if (meta.work != none) return false;
        const tracker = meta.tracker;
        const reach_box: Feet = .{
            .low = .{ feet.low[0] - half_width, feet.low[1], feet.low[2] - half_width },
            .high = .{ feet.high[0] + half_width, feet.high[1] + height, feet.high[2] + half_width },
        };
        const known_words = self.knownWords(slot);
        if (self.bounds_stale) self.gatherBounds();
        // Far from every player, it is settled where no one has it.
        if (self.awayFromPlayers(world, .{ feet.low[0], feet.low[2] }, .{ feet.high[0], feet.high[2] }) > self.trackers[tracker].max_range + slack) {
            if (any(known_words)) return false;
        } else {
            const candidates = self.scratch[self.words..][0..self.words];
            @memcpy(candidates, known_words);
            try self.boxCandidates(world, reach_box, self.trackers[tracker].group, candidates, null);
            const range = self.rangeOf(&self.trackers[tracker], slot);
            for (candidates, 0..) |word, at| {
                var bits = word;
                while (bits != 0) : (bits &= bits - 1) {
                    const player = at * 64 + @ctz(bits);
                    const wanted = switch (self.boxAnswer(slot, world, feet, reach_box, range, player)) {
                        .unsure => return false,
                        .yes => true,
                        .no => false,
                    };
                    if (wanted != has(known_words, player)) return false;
                }
            }
        }
        // Before the tracking pass, which counts on.
        meta.settled_for = self.tick_count + 1;
        meta.settled_heard = self.heard_count;
        meta.settled_box = feet;
        return true;
    }

    fn gatherBounds(self: *Tracking) void {
        self.bounds_stale = false;
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

    // The tick.

    /// Works out every change of audience since the last tick. Run after players were heard,
    /// before kinds send.
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
        self.stats.passes += 1;
        try self.carryOver();
        if (self.seen_footprints.count() > 0) self.seen_footprints.clearRetainingCapacity();
        self.seen_count = 0;
        const space = &self.deps.entities.places.space;
        if (heard) {
            self.heard_count += 1;
            const players = self.deps.players;
            self.changes.update(players);
            for (self.changes.snapshots, 0..) |snapshot, index| {
                self.ready[index] = snapshot.ready;
                self.xs[index] = snapshot.x;
                self.zs[index] = snapshot.z;
                self.reaches[index] = snapshot.reach;
                self.worlds[index] = snapshot.world;
                self.spectating[index] = snapshot.spectator;
            }
            self.bounds_stale = true;
            // Players as subjects move with the players, asked about as they do.
            try self.syncPlayers();
        }
        if (self.tracker_count == 0) {
            space.clearLog();
            self.finalize();
            return;
        }
        if (heard) {
            const resets = self.changes.resetList();
            for (resets) |reset| {
                self.unanchor(reset.player);
                if (reset.was.ready) {
                    // A client that forgot is cleared; one that only stopped being ready is told.
                    if (reset.forgot) try self.near(reset.player, reset.was, .forget) else if (!reset.now.ready) try self.near(reset.player, reset.was, .drop) else try self.near(reset.player, reset.was, .recheck);
                }
            }
            for (resets) |reset| if (reset.now.ready) try self.anchor(reset.player);
            for (self.changes.moveList()) |move| try self.moved(move.player);
            for (self.changes.viewList()) |view| if (self.ready[view.player]) try self.anchor(view.player);
            if (self.deps.streaming) |streaming| try self.terrain(streaming.snapshotVisibility(), resets);
        }
        // Entities placed before tracking began, once.
        if (!self.primed) {
            self.primed = true;
            for (0..self.deps.entities.directory.high()) |slot| if (space.atSlot(@intCast(slot)) != null or space.boxOf(@intCast(slot)) != null) try self.look(@intCast(slot), true);
        }
        // What was offered and not taken first, in full.
        var at: usize = 0;
        while (at < self.retry.len) : (at += 1) try self.again(self.retry.at(at).*);
        self.retry.reset();
        if (heard) try self.lookPlayers();
        try self.logged();
        // Those with ranges of their own, of every player.
        try self.ownRanged();
        if (self.work_overflowed) try self.sweepAll();
        self.finalize();
    }

    /// A player that moved: anchored again when out of its slack, else its edges measured.
    fn moved(self: *Tracking, player: usize) !void {
        if (!self.anchored[player]) return self.anchor(player);
        const dx = self.xs[player] - self.anchor_x[player];
        const dz = self.zs[player] - self.anchor_z[player];
        if (dx * dx + dz * dz > slack * slack) return self.anchor(player);
        return self.slackMove(player);
    }

    /// What was offered and not taken is offered again as it was: what changed since asks again
    /// on its own, and its answer takes the place of the one carried.
    fn carryOver(self: *Tracking) !void {
        // Entries holding nothing are let go once they are half of them, in one sweep.
        if (self.work_empty > 0 and self.work_empty * 2 >= self.work_slots.len) {
            var kept: usize = 0;
            for (0..self.work_slots.len) |index| {
                const slot = self.work_slots.at(index).*;
                const meta = self.metas.at(slot);
                const rows = self.item(@intCast(index));
                if (!any(rows)) {
                    if (meta.work == index) meta.work = none;
                    continue;
                }
                if (kept != index) @memcpy(self.item(@intCast(kept)), rows);
                self.work_slots.at(kept).* = slot;
                self.work_trackers.at(kept).* = self.work_trackers.at(index).*;
                self.work_open.at(kept).* = 0;
                meta.work = @intCast(kept);
                kept += 1;
            }
            self.work_slots.shrink(kept);
            self.work_trackers.shrink(kept);
            self.work_open.shrink(kept);
            self.work_rows.shrink(kept * 2 * self.words);
            self.work_empty = 0;
        }
        self.work_overflowed = false;
        self.finalized = false;
        // Boxed entities some player was unsure of move along their boxes: asked again.
        var at: usize = 0;
        while (at < self.unsettled.len) : (at += 1) _ = try self.retry.append(self.unsettled.at(at).*);
        self.unsettled.reset();
        if (builtin.mode == .debug) try self.checkBoxes();
    }

    /// Every boxed entity is where its box says: what tracking trusts its answers to.
    fn checkBoxes(self: *Tracking) !void {
        const space = &self.deps.entities.places.space;
        if (space.box_count == 0) return;
        for (0..self.deps.entities.directory.high()) |slot| {
            const boxed = space.boxOf(@intCast(slot)) orelse continue;
            const tracker = self.tracker_of[boxed.kind];
            if (tracker == no_tracker or self.trackers[tracker].exact == null) continue;
            _ = try self.exactOf(tracker, boxed);
        }
    }

    /// Chunks sent, taken back or hidden: each such column's entities for its player, and every
    /// column in reach of a player whose view the terrain reset.
    fn terrain(self: *Tracking, visibility: *const Streaming.Visibility, resets: []const PlayerChanges.Reset) !void {
        for (visibility.reset.values()) |player| {
            if (!self.ready[player]) continue;
            for (resets) |reset| {
                if (reset.player == player) break;
            } else {
                self.unanchor(player);
                try self.anchor(player);
            }
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
                const column_x = x + @mod(@mod(cell, side) - @mod(x, side), side);
                const column_z = z + @mod(@divTrunc(cell, side) - @mod(z, side), side);
                try self.eachTouching(self.worlds[player], column_x, column_z, player);
            }
        }
    }

    /// Every entity whose box reaches into a column, for one player: those of its own column and
    /// its neighbours', which a box may reach across, and the boxes listed there.
    fn eachTouching(self: *Tracking, world: u32, column_x: i32, column_z: i32, player: usize) !void {
        var x = column_x - 1;
        while (x <= column_x + 1) : (x += 1) {
            var z = column_z - 1;
            while (z <= column_z + 1) : (z += 1) {
                const tile = self.findTile(world, x >> 3, z >> 3) orelse continue;
                const column: usize = @intCast((x & 7) + (z & 7) * tile_side);
                if (self.tiles.at(tile).occupied & (@as(u64, 1) << @intCast(column)) == 0) continue;
                for (0..self.group_count) |group| try self.columnFor(tile, column, group, player, null, false);
            }
        }
    }

    /// Entities placed, moved, removed and boxed since the log was last taken.
    fn logged(self: *Tracking) !void {
        const space = &self.deps.entities.places.space;
        const log = space.logged();
        var at: usize = 0;
        while (at < log.len) : (at += 1) {
            const change = log.at(at).*;
            self.stats.logged += 1;
            if (change.slot < self.metas.len and self.metas.at(change.slot).looked == self.tick_count) continue;
            try self.look(change.slot, change.event == .placed);
        }
        const overflowed = space.log_overflowed;
        space.clearLog();
        if (overflowed) try self.sweepGone();
    }

    fn ownRanged(self: *Tracking) !void {
        const space = &self.deps.entities.places.space;
        var kept: usize = 0;
        var at: usize = 0;
        while (at < self.own_ranged.len) : (at += 1) {
            const slot = self.own_ranged.at(at).*;
            if (slot >= self.metas.len or self.metas.at(slot).range == 0) continue;
            self.own_ranged.at(kept).* = slot;
            kept += 1;
            if (space.boxOf(slot)) |boxed| {
                try self.checkBox(slot, boxed);
            } else if (space.atSlot(slot)) |placed| try self.checkEveryone(placed.entry, placed.world);
        }
        while (self.own_ranged.len > kept) self.own_ranged.pop();
    }

    /// Every client that has a gone entity is to be told.
    fn owe(self: *Tracking, slot: u32) !void {
        const rows = (try self.workOf(slot)) orelse return;
        for (rows[0..self.words], rows[self.words..], self.knownWords(slot)) |*mask, *answer, have| {
            mask.* |= have;
            answer.* &= ~have;
        }
    }

    /// Asks about an entity again at the next pass, as something it said of itself changed.
    fn relook(self: *Tracking, slot: u32) !void {
        // What was settled was settled for what it said before.
        if (slot < self.metas.len) self.metas.at(slot).settled_for = 0;
        _ = try self.retry.append(slot);
    }

    fn again(self: *Tracking, slot: u32) !void {
        if (slot < self.metas.len and self.metas.at(slot).looked == self.tick_count) return;
        try self.look(slot, true);
    }

    /// The work did not fit: every player anchored again and every entity a client has asked
    /// again.
    fn sweepAll(self: *Tracking) !void {
        self.work_overflowed = false;
        for (0..self.work_slots.len) |index| self.metas.at(self.work_slots.at(index).*).work = none;
        self.work_slots.clear();
        self.work_trackers.clear();
        self.work_open.clear();
        self.opened.reset();
        self.work_empty = 0;
        self.work_rows.clear();
        // The sweep's work is every entity near a player and every one some client has, which
        // the pool bounds and the configured work does not.
        const limit = self.config.work;
        self.config.work = std.math.maxInt(u32);
        defer self.config.work = limit;
        for (0..self.deps.players.records.len) |player| {
            self.unanchor(player);
            if (self.ready[player]) try self.anchor(player);
        }
        for (0..self.metas.len) |index| {
            const slot: u32 = @intCast(index);
            if (self.metas.at(slot).tracker == no_tracker or !any(self.knownWords(slot))) continue;
            try self.look(slot, true);
        }
    }

    /// The log could not hold a removal: every tracked slot no longer placed is looked at.
    fn sweepGone(self: *Tracking) !void {
        const space = &self.deps.entities.places.space;
        for (0..self.metas.len) |index| {
            const slot: u32 = @intCast(index);
            const meta = self.metas.at(slot);
            if (meta.tracker == no_tracker or meta.gone) continue;
            if (space.atSlot(slot) != null and space.boxOf(slot) == null) continue;
            try self.look(slot, true);
        }
    }

    /// Turns each entity's answers into whom to spawn it for and whom to remove it from.
    fn finalize(self: *Tracking) void {
        // Only those opened this pass: the rest hold what is owed already.
        for (0..self.opened.len) |at| {
            const index = self.opened.at(at).*;
            self.work_open.at(index).* = 0;
            const slot = self.work_slots.at(index).*;
            const rows = self.item(index);
            const gone = self.metas.at(slot).gone;
            for (rows[0..self.words], rows[self.words..], self.knownWords(slot)) |*mask_word, *answer_word, have| {
                const mask = mask_word.*;
                const want = if (gone) 0 else answer_word.*;
                mask_word.* = want & ~have & mask;
                answer_word.* = have & ~want & mask;
            }
            if (!any(rows)) self.work_empty += 1;
        }
        self.opened.reset();
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
                if (self.owner.work_trackers.at(index).* != self.tracker) continue;
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

    /// Where the entity in a slot is: a boxed one where its kind says.
    fn placeNow(self: *Tracking, slot: u32) !?Placed {
        const space = &self.deps.entities.places.space;
        if (space.boxOf(slot)) |boxed| {
            const tracker = self.tracker_of[boxed.kind];
            if (tracker == no_tracker) return null;
            return try self.exactOf(tracker, boxed);
        }
        return space.atSlot(slot);
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
        const placed = (try self.placeNow(slot)) orelse return;
        const wanted = self.scratch[0..self.words];
        @memset(wanted, 0);
        const range = self.rangeOf(tracker, slot);
        for (0..self.deps.players.records.len) |player| {
            if (self.sees(slot, placed.entry, placed.world, range, player)) put(wanted, player, true);
        }
        const known_words = self.knownWords(slot);
        var differs = meta.work != none;
        for (known_words, wanted) |have, want| differs = differs or have != want;
        if (!differs) return;
        // Asked after the pass, its entry holds what is owed at once.
        const rows = (if (meta.work != none) self.item(meta.work) else try self.newWork(slot)) orelse return;
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
        const had = any(rows);
        defer if (had and !any(rows)) {
            self.work_empty += 1;
        };
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

    /// Every tile's bits are what each player's anchor says, and every point an anchored player
    /// has is in a column its anchor does not say no for.
    fn checkMasks(self: *Tracking) !void {
        for (0..self.tiles.values.len) |index| {
            const tile: u32 = @intCast(index);
            const held = self.tiles.at(tile);
            if (held.generation == 0) continue;
            const low_x: f64 = @floatFromInt(held.x * tile_side * 16);
            const low_z: f64 = @floatFromInt(held.z * tile_side * 16);
            for (0..self.deps.players.records.len) |player| for (0..self.group_count) |group| for (0..tile_columns) |column| {
                const wanted: Class = if (!self.anchored[player] or self.anchor_world[player] != held.world) .no else classify(self.anchor_x[player], self.anchor_z[player], self.reachOf(group, self.anchor_reach[player]), low_x + @as(f64, @floatFromInt(column % tile_side)) * 16, low_z + @as(f64, @floatFromInt(column / tile_side)) * 16, 16);
                if (wanted != self.classOf(tile, column, group, player)) {
                    std.log.err("event=tracking_mask_mismatch tile={d},{d} column={d} group={d} player={d} wanted={t} kept={t} tick={d}", .{ held.x, held.z, column, group, player, wanted, self.classOf(tile, column, group, player), self.tick_count });
                    return error.TrackingMismatch;
                }
            };
        }
        const space = &self.deps.entities.places.space;
        for (0..self.metas.len) |index| {
            const slot: u32 = @intCast(index);
            const meta = self.metas.at(slot);
            if (meta.tracker == no_tracker or meta.range > 0) continue;
            const placed = space.atSlot(slot) orelse continue;
            const column = entities_module.space.columnOf(placed.world, placed.entry.position);
            const tile = self.findTile(placed.world, column.x >> 3, column.z >> 3) orelse continue;
            const cell: usize = @intCast((column.x & 7) + (column.z & 7) * tile_side);
            for (0..self.deps.players.records.len) |player| {
                if (!has(self.knownWords(slot), player) or !self.anchored[player]) continue;
                if (self.classOf(tile, cell, self.trackers[meta.tracker].group, player) == .no) {
                    std.log.err("event=tracking_known_outside slot={d} player={d} tick={d} looked={d} column={d},{d} anchor={d},{d}", .{ slot, player, self.tick_count, meta.looked, column.x, column.z, self.anchor_x[player], self.anchor_z[player] });
                    return error.TrackingMismatch;
                }
            }
        }
    }

    /// updatePlayer asked of every tracked entity and every player, against what clients have:
    /// with every change confirmed, they agree. For tests and checked benches.
    /// Whether a pair is owed as it is wanted: a spawn owed for one that wants it, a removal owed
    /// for one that does not.
    fn owes(self: *const Tracking, slot: u32, player: usize, wanted: bool) bool {
        const meta = self.metas.at(slot);
        if (meta.work == none or !self.finalized) return false;
        const rows = self.item(meta.work);
        return if (wanted) has(rows[0..self.words], player) else has(rows[self.words..], player);
    }

    pub fn check(self: *Tracking) !void {
        try self.checkMasks();
        for (0..self.metas.len) |index| {
            const slot: u32 = @intCast(index);
            const meta = self.metas.at(slot);
            const placed = try self.placeNow(slot);
            const tracker_index = if (placed) |value| self.tracker_of[value.entry.shape.kind] else meta.tracker;
            if (tracker_index == no_tracker) continue;
            const known_words = self.knownWords(slot);
            for (0..self.deps.players.records.len) |player| {
                const wanted = if (placed) |value| self.sees(slot, value.entry, value.world, self.rangeOf(&self.trackers[tracker_index], slot), player) else false;
                if (wanted != has(known_words, player)) {
                    // Owed as it should be, waiting for room to send: what backpressure leaves.
                    if (self.owes(slot, player, wanted)) continue;
                    std.log.err("event=tracking_mismatch slot={d} player={d} wanted={} known={} placed={} gone={} player_at={d},{d} anchor={d},{d} reach={d} ready={} tick={d} looked={d}", .{ slot, player, wanted, has(known_words, player), placed != null, meta.gone, self.xs[player], self.zs[player], self.anchor_x[player], self.anchor_z[player], self.reaches[player], self.ready[player], self.tick_count, meta.looked });
                    if (placed) |value| std.log.err("event=tracking_mismatch_entity position={any} kind={d}", .{ value.entry.position, value.entry.shape.kind });
                    if (placed) |value| {
                        const column = entities_module.space.columnOf(value.world, value.entry.position);
                        if (self.findTile(value.world, column.x >> 3, column.z >> 3)) |tile| {
                            const cell: usize = @intCast((column.x & 7) + (column.z & 7) * tile_side);
                            std.log.err("event=tracking_mismatch_tile occupied={} class={t} anchored={} edges={d} meta_placed={} meta_column={any}", .{ self.tiles.at(tile).occupied & (@as(u64, 1) << @intCast(cell)) != 0, self.classOf(tile, cell, self.trackers[tracker_index].group, player), self.anchored[player], self.edges[player].len, meta.placed, meta.column });
                        } else std.log.err("event=tracking_mismatch_no_tile", .{});
                    }
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
