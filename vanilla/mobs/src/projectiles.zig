//! Arrows and thrown tridents, as AbstractArrow and ThrownTrident tick: they fall and slow, hit
//! the first block or living thing in their path, stick where they land, and are picked up.
//!
//! Projectiles live on disk, as chunks and entities do, through a records cache of a size set at
//! startup: however many there are, none is dropped; more make the tick slower. A tick streams
//! the flying ones through the cache in tick-list order, which is entity id order, in batches of
//! records that, made together, lie together. Stuck ones are not read at all while their block
//! stands: they come due by time, wake on edits, and are found by block for pickups.
//!
//! A flying projectile traces one ray through block collision shapes a tick, the batch's rays in
//! section order so they share reads, and tests only the living things under its swept box.

const std = @import("std");
const builtin = @import("builtin");
const chunks = @import("chunks");
const sessions = @import("sessions");
const entities = @import("entities");
const records = @import("records");
const metrics = @import("metrics");
const storage = @import("storage");
const game_data = @import("game_data");
const inventories = @import("inventories");
const Worlds = @import("worlds").Worlds;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const Items = @import("vanilla_items").items.Items;
const item_data = @import("vanilla_items").item_data;
const attack_effects = @import("vanilla_items").attack_effects;
const EnchantmentRegistry = @import("vanilla_items").enchantment_registry.EnchantmentRegistry;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const PlayerDamage = @import("vanilla_survival").player_damage.PlayerDamage;
const raycast = @import("vanilla_blocks").raycast;
const world_effects = @import("vanilla_blocks").world_effects;
const entity_effects = @import("vanilla_world").entity_effects;
const body = @import("vanilla_bodies").body;
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
const Mobs = @import("mobs.zig").Mobs;
const Mob = @import("mob.zig").Mob;
const packets = @import("projectile_packets.zig");
const store = @import("projectile_store.zig");
const projectile_claims = @import("projectile_claims.zig");

const assert = std.debug.assert;
const registry = game_data.registry;

comptime {
    // Records are the projectile's bytes as they lie in memory.
    assert(builtin.cpu.arch.endian() == .little);
}

pub const Kind = enum(u8) { arrow, spectral_arrow, trident };
pub const Pickup = enum(u8) { disallowed, allowed, creative_only };
pub const HitSound = enum(u8) { arrow, crossbow };

/// What a shot puts in the world.
pub const Launch = struct {
    kind: Kind,
    world: u32,
    position: [3]f64,
    velocity: [3]f64,
    owner: usize,
    /// What a pickup gives back.
    stack: inventories.Stack,
    /// The weapon it was shot from, whose enchantments shape its hit, as AbstractArrow keeps a
    /// copy of it.
    weapon: ?inventories.Stack = null,
    critical: bool = false,
    pierce: u8 = 0,
    pickup: Pickup = .allowed,
    /// Ticks alight, as Flame sets it.
    fire_ticks: i32 = 0,
    loyalty: u8 = 0,
    foil: bool = false,
    /// The hit sound, which crossbows change.
    hit_sound: HitSound = .arrow,
};

/// A projectile as its record holds it. Its pickup stack and weapon are in inventory slots of its
/// own, 0 and 1, which keep their items defined.
const Projectile = extern struct {
    uuid: u128,
    position: [3]f64,
    velocity: [3]f64,
    pierced: [6]u64 = @splat(0),
    landed_at: u64 = 0,
    despawn_at: u64 = 0,
    /// The tick it was launched on, which its age counts from.
    born_at: u64,
    /// Asleep: the tick it fell asleep on, and the tick it wakes on, its state being the one it
    /// wakes in. Awake, `wake_at` is the tick it may next try to sleep.
    slept_at: u64 = 0,
    wake_at: u64 = 0,
    /// Asleep, where it fell asleep, for waking early.
    start_position: [3]f64 = @splat(0),
    start_velocity: [3]f64 = @splat(0),
    start_yaw: f32 = 0,
    start_pitch: f32 = 0,
    id: u64,
    world: u32,
    owner: u32,
    owner_generation: u32,
    yaw: f32 = 0,
    pitch: f32 = 0,
    fire_ticks: i32,
    life: i32 = 0,
    in_ground_time: i32 = 0,
    stuck: [3]i32 = .{ 0, 0, 0 },
    stuck_state: u16 = 0,
    kind: Kind,
    pickup: Pickup,
    hit_sound: HitSound,
    pierce: u8,
    pierced_count: u8 = 0,
    loyalty: u8,
    shake: u8 = 0,
    critical: bool,
    foil: bool,
    has_weapon: bool,
    in_ground: bool = false,
    in_water: bool = false,
    /// Set by a chunk edit: the block it is stuck in may have gone.
    loose: bool = false,
    left_owner: bool = false,
    dealt_damage: bool = false,
    returning: bool = false,
    removed: bool = false,
    /// Whether viewers must be told of a change of motion or state this tick.
    impulse: bool = true,
    data_changed: bool = true,
    /// A stuck arrow leaves the tick: nothing about it changes until its block does, its time is
    /// up, or a player takes it.
    parked: bool = false,
    /// A flying one left alone until it wakes: nothing near its path could change it, so its
    /// ticks are worked out when it wakes, as they would have gone.
    asleep: bool = false,
    /// Asleep through its update tick too: it wakes only to send the update, its state already
    /// past that tick.
    synced: bool = false,
    start_shake: u8 = 0,
    /// It has a sleeping entry instead of a ticking one: asleep, or woken this tick.
    marked: bool = false,

    /// Back to where it fell asleep.
    fn restart(self: *Projectile) void {
        self.position = self.start_position;
        self.velocity = self.start_velocity;
        self.yaw = self.start_yaw;
        self.pitch = self.start_pitch;
        self.shake = self.start_shake;
    }

    /// Without what sleeping keeps, which a projectile that never sleeps does not have.
    fn forgetSleep(self: *Projectile) void {
        self.asleep = false;
        self.synced = false;
        self.marked = false;
        self.slept_at = 0;
        self.wake_at = 0;
        self.start_position = @splat(0);
        self.start_velocity = @splat(0);
        self.start_yaw = 0;
        self.start_pitch = 0;
        self.start_shake = 0;
    }
};

/// A record in hand for a batch: the projectile and its viewers where the cache keeps them, edited
/// in place, the lease, and whether it was in the ground when read, which says what entries it has
/// besides its record.
const Held = struct {
    projectile: *Projectile,
    row: []u64,
    lease: records.Cache.Lease,
    was_in_ground: bool,
    was_parked: bool,
    was_marked: bool = false,
    /// Woken only to send its update: nothing else happens to it this tick.
    quick: bool = false,
};

/// A moving projectile of a batch by the section it is in.
const Order = struct {
    index: u32,
    key: u64,

    fn before(_: void, a: Order, b: Order) bool {
        return a.key < b.key;
    }
};

/// A change to an entry that is only its key.
const IndexOp = struct {
    key: store.Key,
    mark: bool,

    fn before(_: void, a: IndexOp, b: IndexOp) bool {
        return std.mem.order(u8, a.key.slice(), b.key.slice()) == .lt;
    }
};

/// Where a player stood, by its connection, and its game mode, which decides what it may pick up.
const Seen = struct { generation: u32 = 0, world: u32 = 0, position: [3]f64 = @splat(0), stage: u8 = 0, gamemode: i8 = 0 };

pub const Projectiles = struct {
    pub const id = "minecraft:projectiles";
    pub const Configuration = struct {
        /// Records in memory. More projectiles than this stream through it, a batch at a time.
        cache_records: usize = 1024,
        /// Sections whose blocks of 4x4x4 are known to hold, or not, what affects projectiles: a
        /// power of two. Forgetting one only means looking at it again.
        space_sections: usize = 4096,
        /// Projectiles that may sleep at once; past it they stay awake.
        claims: usize = 65536,
        /// Whether flying projectiles with nothing near their path sleep. Off, every one ticks
        /// every tick, which is what sleeping must match.
        sleep: bool = true,
        /// Keep a hash of everything asked to be sent, for runs to be compared by.
        trace_sends: bool = false,
        seed: u64 = 0x6172726f77,
    };
    pub const Dependencies = struct {
        players: *Players,
        player_states: *PlayerStates,
        mobs: *Mobs,
        worlds: *Worlds,
        chunks: *chunks.Chunks,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        menus: *PlayerInventory,
        damage: *PlayerDamage,
        enchantments: *EnchantmentRegistry,
        client: *ClientRegistries,
        record_workspaces: *records.Workspaces,
        metrics: *metrics.Registry,
        storage: storage.Space,
    };
    /// AbstractArrow and its kin track 4 chunks away.
    const tracking_blocks = 64.0;
    /// ServerEntity's update interval for arrows.
    const update_interval = 20;
    const half_width = 0.25;
    const height = 0.5;
    /// The chunk reads one tick of projectiles shares: a ray's eight cells at most.
    const window_sections = 8;
    /// Records a batch holds, a whole number of scan batches.
    const batch_max = store.Pass.batch;
    /// How records lie in the cache: a projectile, then its viewer row of words.
    const record_align = @alignOf(Projectile);
    comptime {
        assert(@sizeOf(Projectile) % @alignOf(u64) == 0);
    }
    /// Entry changes a batch's projectiles make: as they land, fly again, sleep or go, five at
    /// most each.
    const ops_per_batch = batch_max * 5 + 1;
    /// Changes a pass holds back across its batches, so the cache orders its keys once a pass
    /// rather than once a batch.
    const ops_max = ops_per_batch * 64;
    /// Keys one reservation takes, as records reserve them.
    const reserve_max = 128;
    /// The most players a viewer row has room for.
    const max_row_bytes = 64;
    /// Chunks whose nearby players one tick keeps, each with up to every player.
    const shared_columns = 256;
    /// Counters of stuck projectiles by hashed cell.
    const cell_count = 1 << 16;

    const Column = struct { world: u32, x: i32, z: i32, nearness: Nearness };
    /// Where a chunk's shared players are, and for those who may be hit, the box around them all.
    const Range = struct { start: u32, len: u32, bounds: body.Box = undefined };
    /// The players who may be hit near a chunk: their slots, their boxes, and the box around them.
    const Targets = struct { players: []const u32, boxes: []const body.Box, bounds: ?body.Box };

    deps: Dependencies,
    cache: records.Cache,
    record_bytes: usize,
    chunk_client: chunks.Chunks.Client,
    window: chunks.ReadWindow(window_sections),
    /// How many projectiles there are, how many fly, and how many removals and wakings are owed.
    count: u64 = 0,
    ticking: u64 = 0,
    removals: u64 = 0,
    woken: u64 = 0,
    /// Stuck projectiles by the cell they are in, hashed: a cell whose count is zero holds none,
    /// so pickups and edits look only where something is stuck. A count at its most stays there.
    cells: []u16,
    /// Ticks since the world began, which despawns count by; kept across restarts.
    now: u64 = 0,
    /// A failure in a chunk edit observer, raised at the next tick.
    failure: ?anyerror = null,
    /// Changes to entries that are only keys, waiting for the end of their batch.
    ops: []IndexOp,
    op_count: usize = 0,
    /// Within a pass whose keys its batches do not read back, changes wait for its end.
    holding_index: bool = false,
    /// The space sleeping projectiles will pass through.
    claims: projectile_claims.Claims,
    sleeping: usize = 0,
    sleep: bool,
    /// A running hash of everything asked to be sent, when tests trace it.
    sent: u64 = 0,
    tracing: bool,
    /// The box around each world's players this tick, horizontally, for telling at once that
    /// no one is near: a world, and its least and greatest x and z.
    players_near: [players_near_max]struct { world: u32, low: [2]f64, high: [2]f64 } = undefined,
    players_near_count: usize = 0,
    players_near_tick: u64 = std.math.maxInt(u64),
    /// Sleepers something came near since the last tick, to wake before the flying. With more
    /// than fit, every sleeper wakes.
    rousing: []u32,
    rousing_count: usize = 0,
    rouse_all: bool = false,
    /// Sleepers waking this tick, by id, for the flying to take among the others.
    waking: []u64,
    waking_count: usize = 0,
    /// The batch in hand.
    held: []Held,
    held_count: usize = 0,
    /// Those of the batch written back already, whose records the cache has again.
    held_settled: usize = 0,
    order: []Order,
    traces: []?raycast.Hit,
    /// The motion each projectile of the batch began its tick with, which its move goes by.
    motions: [][3]f64,
    row_words: usize,
    /// The players near each chunk with projectiles, found once a tick: who may be hit as a list,
    /// and who sees, as two rows of words, those in range of all of the chunk and those in range
    /// of some of it.
    columns: std.AutoHashMapUnmanaged(Column, Range),
    candidates: []u32,
    candidate_boxes: []body.Box,
    candidate_count: usize = 0,
    /// The last chunk looked up for each, which the next projectile shares more often than not.
    last_columns: [2]?Column = .{ null, null },
    last_ranges: [2]Range = undefined,
    masks: []u64,
    mask_count: usize = 0,
    /// The players near one chunk past the shared ones, kept for one projectile.
    overflow: []u32,
    overflow_boxes: []body.Box,
    /// Where each player was last tick, to tell who moved; and when anyone last did.
    seen: []Seen,
    moved: std.DynamicBitSetUnmanaged,
    moved_at: u64 = 0,
    /// The last tick an arrow landed: until it stops shaking, everyone looks for pickups.
    landed_at: u64 = 0,
    effects: world_effects.Effects,
    random: std.Random.DefaultPrng,
    scratch: std.heap.FixedBufferAllocator,
    entity_types: [3]u32,
    player_type: u32,
    /// States an arrow counts as in water in.
    watery: std.DynamicBitSetUnmanaged,
    /// Per block state, bit `affecting`: whether a projectile in or through it can be changed by
    /// it. Space without any is crossed without reading its blocks.
    affecting_states: []u8,
    /// Which blocks of 4x4x4 of sections read lately hold such states.
    space: chunks.occupancy.Table,
    air_state: u16,
    /// The height of the world last asked about this tick, as definitions change only between
    /// ticks.
    height_world: ?u32 = null,
    world_height: raycast.Height = .unbounded,
    /// The batch of packets going to one set of viewers, and what each packet is for.
    outbox: sessions.Service.Broadcast,
    outbox_audience: []u64,
    outbox_pending: [sessions.Service.batch_max]Pending = undefined,
    outbox_count: usize = 0,
    recipients: []sessions.Service.Target,
    /// One projectile's viewers to tell of its spawn and of its removal, those out of room this
    /// tick, and those one update goes to.
    joining: []u64,
    leaving: []u64,
    starved: []u64,
    audience: []u64,
    /// Packets queued and packets some viewer took, by purpose: spawns, updates, removals.
    queued: [3]u64 = @splat(0),
    taken: [3]u64 = @splat(0),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Projectiles {
        const self = try allocate(allocator, io, configuration, deps);
        try self.recover();
        return self;
    }

    /// Everything but what the world kept.
    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Projectiles {
        // A batch, and the entries it makes or removes as its projectiles land, go and fall.
        if (configuration.cache_records < 4 * batch_max) return error.InvalidConfiguration;
        if ((deps.players.records.len + 63) / 64 * 8 > max_row_bytes) return error.InvalidConfiguration;
        const self = try allocator.create(Projectiles);
        const row_words = (deps.players.records.len + 63) / 64;
        const record_bytes = @sizeOf(Projectile) + row_words * 8;
        const chunk_client = try deps.chunks.simulation(window_sections);
        var columns: std.AutoHashMapUnmanaged(Column, Range) = .empty;
        try columns.ensureTotalCapacity(allocator, shared_columns * 2);
        const players = deps.players.records.len;
        const cells = try allocator.alloc(u16, cell_count);
        @memset(cells, 0);
        self.* = .{
            .deps = deps,
            .cache = try records.Cache.init(allocator, io, records.Table.init(deps.storage, deps.record_workspaces.resources), .{
                .metrics = deps.metrics,
                .metrics_namespace = "projectiles.cache",
                .slots = configuration.cache_records,
                .key_bytes = store.key_bytes,
                // Slots a whole number of alignments apart, so a record is edited where it lies.
                .value_bytes = std.mem.alignForward(usize, record_bytes, record_align),
                .scan_batch = store.Pass.batch,
            }),
            .record_bytes = record_bytes,
            .chunk_client = chunk_client,
            .window = .init(chunk_client),
            .cells = cells,
            .ops = try allocator.alloc(IndexOp, ops_max),
            .held = try allocator.alloc(Held, batch_max),
            .claims = try projectile_claims.Claims.init(allocator, configuration.claims),
            .sleep = configuration.sleep,
            .tracing = configuration.trace_sends,
            .rousing = try allocator.alloc(u32, rousing_max),
            .waking = try allocator.alloc(u64, configuration.claims),
            .order = try allocator.alloc(Order, batch_max),
            .traces = try allocator.alloc(?raycast.Hit, batch_max),
            .motions = try allocator.alloc([3]f64, batch_max),
            .row_words = row_words,
            .columns = columns,
            .candidates = try allocator.alloc(u32, shared_columns * players),
            .candidate_boxes = try allocator.alloc(body.Box, shared_columns * players),
            .masks = try allocator.alloc(u64, shared_columns * 2 * row_words),
            .overflow = try allocator.alloc(u32, players),
            .overflow_boxes = try allocator.alloc(body.Box, players),
            .seen = try allocator.alloc(Seen, players),
            .moved = try .initEmpty(allocator, players),
            .effects = try .init(allocator, deps.players),
            .random = .init(configuration.seed),
            .scratch = .init(try allocator.alloc(u8, 16 * 1024)),
            .entity_types = .{ try entityType("minecraft:arrow"), try entityType("minecraft:spectral_arrow"), try entityType("minecraft:trident") },
            .player_type = try entityType("minecraft:player"),
            .watery = try wetStates(allocator),
            .affecting_states = try affectingStates(allocator),
            .space = try chunks.occupancy.Table.init(allocator, configuration.space_sections),
            .air_state = @intCast(game_data.registry.blockStateId("minecraft:air").?),
            .outbox = try .init(allocator, deps.players.deps.sessions, sessions.Service.batch_max * deps.players.deps.sessions.config.protocols.len),
            .outbox_audience = try allocator.alloc(u64, row_words),
            .recipients = try allocator.alloc(sessions.Service.Target, players),
            .joining = try allocator.alloc(u64, row_words),
            .leaving = try allocator.alloc(u64, row_words),
            .starved = try allocator.alloc(u64, row_words),
            .audience = try allocator.alloc(u64, row_words),
        };
        @memset(self.seen, .{});
        try deps.chunks.observe(.init(self, blocksChanged));
        return self;
    }

    /// The clock and the counts, from what the world kept.
    fn recover(self: *Projectiles) !void {
        const clock = try self.cache.acquire(&.{0});
        defer clock.release();
        if (clock.read()) |bytes| {
            if (bytes.len != 8) return error.Corrupt;
            self.now = std.mem.readInt(u64, bytes[0..8], .little);
        }
        inline for (.{ .{ store.Prefix.record, "count" }, .{ store.Prefix.ticking, "ticking" }, .{ store.Prefix.removal, "removals" }, .{ store.Prefix.woken, "woken" }, .{ store.Prefix.sleeping, "sleeping" }, .{ store.Prefix.stuck, "" } }) |entry| {
            var pass = store.Pass.init(&self.cache, store.under(entry[0]));
            while (true) {
                const keys = try pass.next();
                if (keys.len == 0) break;
                if (entry[1].len == 0) {
                    for (keys) |key| self.countCell(store.stuckBlock(key.slice()), stuckWorld(key.slice()), 1);
                } else @field(self, entry[1]) += keys.len;
            }
        }
        // Claims live in memory: after a restart every sleeper wakes on the first tick.
        self.rouse_all = self.sleeping > 0;
    }

    fn stuckWorld(stuck_key: []const u8) u32 {
        return std.mem.readInt(u32, stuck_key[1..5], .big);
    }

    fn cellIndex(world_id: u32, x: i32, z: i32) usize {
        const hash = (@as(u64, @as(u32, @bitCast(x))) *% 0x9e3779b97f4a7c15) ^ (@as(u64, @as(u32, @bitCast(z))) *% 0xc2b2ae3d27d4eb4f) ^ (@as(u64, world_id) *% 0x165667b19e3779f9);
        return @intCast((hash >> 40) & (cell_count - 1));
    }

    /// Counts a stuck projectile into or out of the cell of a block.
    fn countCell(self: *Projectiles, block: [3]i32, world_id: u32, delta: i2) void {
        const counter = &self.cells[cellIndex(world_id, block[0] >> store.cell_shift, block[2] >> store.cell_shift)];
        if (counter.* == std.math.maxInt(u16)) return;
        if (delta > 0) counter.* += 1 else {
            assert(counter.* > 0);
            counter.* -= 1;
        }
    }

    fn cellEmpty(self: *const Projectiles, world_id: u32, cell_x: i32, cell_z: i32) bool {
        return self.cells[cellIndex(world_id, cell_x, cell_z)] == 0;
    }

    pub fn checkpoint(self: *Projectiles, _: storage.Space) !void {
        const clock = try self.cache.acquire(&.{0});
        std.mem.writeInt(u64, clock.edit()[0..8], self.now, .little);
        clock.commit(8);
        // Writeback takes only entries no one holds.
        clock.release();
        try self.cache.flush();
    }

    /// Puts a projectile in the world, moving as shot, with its pickup stack and weapon in slots of
    /// its own.
    pub fn launch(self: *Projectiles, request: Launch) !void {
        assert(request.owner < self.deps.players.records.len);
        const player = &self.deps.players.records[request.owner];
        const entity = try self.deps.entities.reserveIds(1);
        if (entity > std.math.maxInt(i32)) return error.IdExhausted;
        var projectile: Projectile = .{
            .id = entity,
            .uuid = self.random.random().int(u128) & ~@as(u128, 0xf000 << 64) | (@as(u128, 0x4000) << 64),
            .kind = request.kind,
            .world = request.world,
            .position = request.position,
            .velocity = request.velocity,
            .born_at = self.now,
            .owner = @intCast(request.owner),
            .owner_generation = if (player.handle) |handle| handle.generation else 0,
            .has_weapon = request.weapon != null,
            .critical = request.critical,
            .pierce = request.pierce,
            .pickup = request.pickup,
            .fire_ticks = request.fire_ticks,
            .loyalty = request.loyalty,
            .foil = request.foil,
            .hit_sound = request.hit_sound,
        };
        face(&projectile);
        try self.hand(projectile.uuid, 0, request.stack);
        if (request.weapon) |weapon| try self.hand(projectile.uuid, 1, weapon);
        // A new id has nothing on disk.
        var bytes: [@sizeOf(Projectile) + max_row_bytes]u8 = undefined;
        @memcpy(bytes[0..@sizeOf(Projectile)], std.mem.asBytes(&projectile));
        @memset(bytes[@sizeOf(Projectile)..self.record_bytes], 0);
        try self.create(store.byId(.record, entity), bytes[0..self.record_bytes]);
        self.mark(store.byId(.ticking, entity));
        try self.applyIndex();
        self.count += 1;
        self.ticking += 1;
    }

    /// Puts a stack in a projectile's own slot, or empties it.
    fn hand(self: *Projectiles, owner: u128, index: u16, stack: ?inventories.Stack) !void {
        const at: inventories.Slot = .{ .owner = owner, .index = index };
        const held = try self.deps.inventories.get(at);
        if (held.stack == null and stack == null) return;
        if (!try self.deps.inventories.set(at, held.revision, stack)) return error.ProjectileSlotConflict;
    }

    /// An entry that is only its key, made with the others of its batch.
    fn mark(self: *Projectiles, key: store.Key) void {
        assert(self.op_count < self.ops.len);
        self.ops[self.op_count] = .{ .key = key, .mark = true };
        self.op_count += 1;
    }

    /// An entry the projectile's state says exists, taken away with the others of its batch.
    fn unmark(self: *Projectiles, key: store.Key) void {
        assert(self.op_count < self.ops.len);
        self.ops[self.op_count] = .{ .key = key, .mark = false };
        self.op_count += 1;
    }

    /// Applies the batch's entry changes in key order, so neighbours share pages. Nothing is
    /// read: a projectile's state says which of its entries exist, so a new one is written and a
    /// gone one deleted as it is.
    fn applyIndex(self: *Projectiles) !void {
        const ops = self.ops[0..self.op_count];
        defer self.op_count = 0;
        std.mem.sortUnstable(IndexOp, ops, {}, IndexOp.before);
        var done: usize = 0;
        while (done < ops.len) {
            const count = @min(ops.len - done, reserve_max);
            var keys: [reserve_max][]const u8 = undefined;
            for (ops[done..][0..count], keys[0..count]) |*op, *key| key.* = op.key.slice();
            var leases: [reserve_max]records.Cache.Lease = undefined;
            try self.reserve(keys[0..count], leases[0..count]);
            for (ops[done..][0..count], leases[0..count]) |op, lease| {
                defer lease.release();
                if (!self.cache.entries[lease.index].loaded) lease.reserve().load(null);
                if (op.mark) {
                    _ = lease.edit();
                    lease.commit(0);
                } else lease.remove();
            }
            done += count;
        }
    }

    /// Slots for keys without reading storage, writing back what must make room.
    fn reserve(self: *Projectiles, keys: []const []const u8, leases: []records.Cache.Lease) !void {
        assert(keys.len <= reserve_max);
        while (true) {
            var victims: [reserve_max]records.Cache.Lease = undefined;
            switch (try self.cache.reserveMany(keys, leases, &victims, self.cache.entries.len)) {
                .ready => return,
                .blocked => return error.CachePinned,
                .writeback => |dirty| {
                    defer for (dirty) |victim| victim.release();
                    var writes: [reserve_max]records.Write = undefined;
                    for (dirty, writes[0..dirty.len]) |victim, *write| write.* = .{ .key = victim.key(), .value = victim.read() };
                    try self.cache.writeBack(writes[0..dirty.len]);
                    for (dirty) |victim| victim.markWritten();
                },
            }
        }
    }

    /// Writes an entry its key says is new, without reading storage for it.
    fn create(self: *Projectiles, key: store.Key, bytes: []const u8) !void {
        var leases: [1]records.Cache.Lease = undefined;
        try self.reserve(&.{key.slice()}, &leases);
        defer leases[0].release();
        if (self.cache.entries[leases[0].index].loaded) {
            if (leases[0].read() != null) return error.Corrupt;
            @memcpy(leases[0].edit()[0..bytes.len], bytes);
            return leases[0].commit(bytes.len);
        }
        const fill = leases[0].reserve();
        @memcpy(fill.bytes[0..bytes.len], bytes);
        fill.publish(bytes.len);
    }

    /// A stuck projectile whose block was edited is woken to look at it on the next tick.
    fn blocksChanged(self: *Projectiles, section: chunks.Section, edits: []const chunks.BlockEdit, _: []const u16) void {
        self.space.forget(section);
        // Sleepers whose path the edited section reaches, within a block, look again.
        const low: [3]f64 = .{ @floatFromInt(section.x * 16 - 1), @floatFromInt(section.y * 16 - 1), @floatFromInt(section.z * 16 - 1) };
        self.rouseMeeting(section.world, .{ .low = low, .high = .{ low[0] + 18, low[1] + 18, low[2] + 18 } }, 0);
        if (self.count == self.ticking + self.sleeping or self.failure != null) return;
        for (edits) |edit| {
            const index: i32 = edit.index;
            const at: [3]i32 = .{ section.x * 16 + (index & 15), section.y * 16 + (index >> 8), section.z * 16 + ((index >> 4) & 15) };
            self.wakeAt(section.world, at) catch |err| {
                self.failure = err;
                return;
            };
        }
    }

    fn wakeAt(self: *Projectiles, world_id: u32, at: [3]i32) !void {
        if (self.cellEmpty(world_id, at[0] >> store.cell_shift, at[2] >> store.cell_shift)) return;
        var pass = store.Pass.init(&self.cache, store.stuck(world_id, at[0], at[2], at[1], null));
        while (true) {
            const keys = try pass.next();
            if (keys.len == 0) return;
            var ids: [store.Pass.batch]u64 = undefined;
            for (keys, ids[0..keys.len]) |key, *entity| entity.* = store.Key.id(key.slice());
            for (ids[0..keys.len]) |entity| try self.wakeOne(entity);
        }
    }

    /// Marks a stuck projectile woken, its record too, so what frees it knows to take the mark.
    fn wakeOne(self: *Projectiles, entity: u64) !void {
        const held = try self.cache.acquire(store.byId(.record, entity).slice());
        defer held.release();
        const bytes = held.read() orelse return error.Corrupt;
        var projectile: Projectile = undefined;
        @memcpy(std.mem.asBytes(&projectile), bytes[0..@sizeOf(Projectile)]);
        if (projectile.loose) return;
        projectile.loose = true;
        const length = bytes.len;
        @memcpy(held.edit()[0..@sizeOf(Projectile)], std.mem.asBytes(&projectile));
        held.commit(length);
        try self.create(store.byId(.woken, entity), &.{});
        self.woken += 1;
    }

    pub fn tick(self: *Projectiles) !void {
        self.now += 1;
        self.height_world = null;
        if (self.failure) |err| return err;
        if (self.count == 0 and self.removals == 0) return;
        // One window for every projectile this tick: arrows flying together read their
        // sections once. Nothing a projectile does edits blocks, so holding it is safe.
        defer self.window.deinit();
        if (self.columns.count() > 0) self.columns.clearRetainingCapacity();
        self.last_columns = .{ null, null };
        self.candidate_count = 0;
        self.mask_count = 0;
        @memset(self.starved, 0);
        try self.notice();
        self.watch();
        try self.holdingIndex(rouse);
        // Everything this tick sends goes out by the end of it.
        defer self.flush() catch |err| {
            self.failure = err;
        };
        try self.retire();
        try self.expire();
        try self.wake();
        try self.holdingIndex(fly);
        try self.visitParked();
        try self.collect();
    }

    /// The flying, in tick-list order, a batch at a time: those ticking, and the sleepers waking
    /// this tick merged in among them by id.
    fn fly(self: *Projectiles) !void {
        if (self.ticking == 0 and self.waking_count == 0) return;
        var pass = store.Pass.init(&self.cache, store.under(.ticking));
        var keys: []const store.Key = &.{};
        var key_at: usize = 0;
        var woken_at: usize = 0;
        var ids: [batch_max]u64 = undefined;
        // The first so many stay cached from tick to tick; past them, the pass streams through a
        // few slots, so a pass larger than the cache reads only what does not fit.
        const resident = self.cache.entries.len - 4 * batch_max;
        var visited: usize = 0;
        while (true) {
            var count: usize = 0;
            while (count < batch_max) {
                if (key_at == keys.len and !pass.done) {
                    keys = try pass.next();
                    key_at = 0;
                }
                const ticking: ?u64 = if (key_at < keys.len) store.Key.id(keys[key_at].slice()) else null;
                const waking: ?u64 = if (woken_at < self.waking_count) self.waking[woken_at] else null;
                if (ticking == null and waking == null) break;
                if (waking == null or (ticking != null and ticking.? < waking.?)) {
                    ids[count] = ticking.?;
                    key_at += 1;
                } else {
                    ids[count] = waking.?;
                    woken_at += 1;
                }
                count += 1;
            }
            if (count == 0) return;
            try self.hold(ids[0..count], visited + count > resident);
            visited += count;
            for (self.held[0..self.held_count]) |*held| {
                const projectile = held.projectile;
                if (!projectile.asleep) continue;
                if (projectile.synced and self.now == projectile.wake_at) {
                    projectile.asleep = false;
                    projectile.synced = false;
                    held.quick = true;
                } else self.awaken(projectile);
            }
            try self.trace();
            for (self.held[0..self.held_count]) |*held| {
                // Its tick was worked out when it fell asleep: only its update is left to send.
                if (held.quick) try self.updates(held) else {
                    try self.step(held);
                    if (!held.projectile.removed) try self.replicate(held);
                }
                if (!held.projectile.removed) try self.lull(held);
                // One that did not sleep again ticks from now on.
                if (!held.projectile.asleep) held.projectile.marked = false;
            }
            try self.settle();
        }
    }


    /// Ids from a pass, as many as fill whole scan batches into `output`.
    fn gather(pass: *store.Pass, output: []u64) !usize {
        var count: usize = 0;
        while (count + store.Pass.batch <= output.len) {
            const keys = try pass.next();
            if (keys.len == 0) break;
            for (keys) |key| {
                output[count] = store.Key.id(key.slice());
                count += 1;
            }
        }
        return count;
    }

    /// Takes the records of a batch in hand, in the order given.
    /// A transient hold reads what is not cached into slots evicted first, for a pass past what
    /// the cache keeps.
    fn hold(self: *Projectiles, ids: []const u64, transient: bool) !void {
        assert(self.held_count == 0 and ids.len <= batch_max);
        var keys: [batch_max]store.Key = undefined;
        var slices: [batch_max][]const u8 = undefined;
        var leases: [batch_max]records.Cache.Lease = undefined;
        for (ids, 0..) |entity, index| {
            keys[index] = store.byId(.record, entity);
            slices[index] = keys[index].slice();
        }
        if (transient) try self.cache.acquireManyTransient(slices[0..ids.len], leases[0..ids.len]) else try self.cache.acquireMany(slices[0..ids.len], leases[0..ids.len]);
        for (leases[0..ids.len]) |lease| {
            const bytes = lease.read() orelse null;
            if (bytes == null or bytes.?.len != self.record_bytes) {
                for (leases[0..ids.len]) |other| other.release();
                return error.Corrupt;
            }
        }
        for (leases[0..ids.len], self.held[0..ids.len]) |lease, *held| {
            // The cache's own bytes: the batch edits them where they are, and settling commits.
            const bytes: []align(record_align) u8 = @alignCast(lease.edit()[0..self.record_bytes]);
            const projectile: *Projectile = @ptrCast(bytes[0..@sizeOf(Projectile)]);
            const row: []u64 = @alignCast(std.mem.bytesAsSlice(u64, bytes[@sizeOf(Projectile)..]));
            held.* = .{ .projectile = projectile, .row = row, .lease = lease, .was_in_ground = projectile.in_ground, .was_parked = projectile.parked, .was_marked = projectile.marked };
        }
        self.held_count = ids.len;
    }

    /// Writes the batch back: each record as it is now, its entries as it became, and its lease
    /// let go. A projectile that went leaves its removal for viewers who knew of it.
    fn settle(self: *Projectiles) !void {
        defer {
            self.held_count = 0;
            self.held_settled = 0;
        }
        for (self.held[0..self.held_count]) |*held| {
            defer {
                held.lease.release();
                self.held_settled += 1;
            }
            const projectile = held.projectile;
            if (projectile.removed) {
                // Its entries and slots go while the record is still in hand, then the record.
                try self.forgetEntries(held);
                held.lease.commit(self.record_bytes);
                held.lease.remove();
                continue;
            }
            if (projectile.in_ground and projectile.kind != .trident and !projectile.parked) {
                projectile.parked = true;
                projectile.despawn_at = projectile.landed_at + 1200;
            }
            held.lease.commit(self.record_bytes);
            self.moveEntries(held);
        }
        if (!self.holding_index or self.op_count + ops_per_batch > self.ops.len) try self.applyIndex();
    }

    /// Runs a pass with its entry changes held back to its end.
    fn holdingIndex(self: *Projectiles, comptime pass: anytype) !void {
        assert(!self.holding_index);
        self.holding_index = true;
        defer self.holding_index = false;
        try pass(self);
        try self.applyIndex();
    }

    /// The entries of a projectile that changed state: flying, stuck, parked.
    fn moveEntries(self: *Projectiles, held: *Held) void {
        const projectile = held.projectile;
        const entity = projectile.id;
        const was_ticking = !held.was_parked and !held.was_marked;
        const ticking = !projectile.parked and !projectile.marked;
        if (held.was_marked and !projectile.marked) {
            self.unmark(store.byId(.sleeping, entity));
            self.sleeping -= 1;
        }
        if (!held.was_marked and projectile.marked) {
            self.mark(store.byId(.sleeping, entity));
            self.sleeping += 1;
        }
        if (was_ticking and !ticking) {
            self.unmark(store.byId(.ticking, entity));
            self.ticking -= 1;
        }
        if (!was_ticking and ticking) {
            self.mark(store.byId(.ticking, entity));
            self.ticking += 1;
        }
        if (held.was_in_ground and !projectile.in_ground) self.unstick(held);
        if (!held.was_in_ground and projectile.in_ground) {
            self.mark(self.stuckKey(projectile));
            self.countCell(projectile.stuck, projectile.world, 1);
        }
        if (held.was_parked and !projectile.parked) {
            self.unmark(store.due(projectile.despawn_at, entity));
            self.unmark(store.parked(group(entity), entity));
        }
        if (!held.was_parked and projectile.parked) {
            self.mark(store.due(projectile.despawn_at, entity));
            self.mark(store.parked(group(entity), entity));
        }
    }

    /// A projectile that went: its entries and slots go, and viewers who knew of it are owed its
    /// removal.
    fn forgetEntries(self: *Projectiles, held: *Held) !void {
        const projectile = held.projectile;
        const entity = projectile.id;
        if (held.was_marked) {
            self.unmark(store.byId(.sleeping, entity));
            self.sleeping -= 1;
        } else if (!held.was_parked) {
            self.unmark(store.byId(.ticking, entity));
            self.ticking -= 1;
        }
        if (held.was_in_ground) self.unstick(held);
        if (held.was_parked) {
            self.unmark(store.due(projectile.despawn_at, entity));
            self.unmark(store.parked(group(entity), entity));
        }
        try self.hand(projectile.uuid, 0, null);
        if (projectile.has_weapon) try self.hand(projectile.uuid, 1, null);
        self.count -= 1;
        const known = for (held.row) |word| {
            if (word != 0) break true;
        } else false;
        if (!known) return;
        // One removal for an id, ever: it is new.
        var value: [8 + max_row_bytes]u8 = @splat(0);
        std.mem.writeInt(i32, value[0..4], networkId(projectile), .little);
        @memcpy(value[8..][0 .. self.row_words * 8], std.mem.sliceAsBytes(held.row));
        try self.create(store.byId(.removal, entity), value[0 .. 8 + self.row_words * 8]);
        self.removals += 1;
        try self.queue(entity, held.row, .remove, true, packets.writeRemove, .{networkId(projectile)});
    }

    /// Takes a projectile's stuck entry away, and with it a waking it is still owed.
    fn unstick(self: *Projectiles, held: *Held) void {
        const projectile = held.projectile;
        self.unmark(self.stuckKey(projectile));
        self.countCell(projectile.stuck, projectile.world, -1);
        if (!projectile.loose) return;
        projectile.loose = false;
        self.unmark(store.byId(.woken, projectile.id));
        self.woken -= 1;
    }

    fn stuckKey(_: *const Projectiles, projectile: *const Projectile) store.Key {
        return store.stuck(projectile.world, projectile.stuck[0], projectile.stuck[2], projectile.stuck[1], projectile.id);
    }

    /// Which tick of a second a parked arrow looks over its viewers on.
    fn group(entity: u64) u8 {
        return @intCast(entity % update_interval);
    }

    /// AbstractArrow.tickDespawn for the parked: a minute in the ground and it goes, in the order
    /// they came due.
    fn expire(self: *Projectiles) !void {
        if (self.count == self.ticking + self.sleeping) return;
        var pass = store.Pass.init(&self.cache, store.under(.due));
        var ids: [batch_max]u64 = undefined;
        while (true) {
            var count: usize = 0;
            var past = false;
            while (count + store.Pass.batch <= ids.len and !past) {
                const keys = try pass.next();
                if (keys.len == 0) break;
                for (keys) |key| {
                    if (store.dueAt(key.slice()) > self.now) {
                        past = true;
                        break;
                    }
                    ids[count] = store.Key.id(key.slice());
                    count += 1;
                }
            }
            if (count == 0) return;
            try self.hold(ids[0..count], false);
            for (self.held[0..self.held_count]) |*held| {
                assert(held.projectile.parked and held.projectile.despawn_at <= self.now);
                held.projectile.removed = true;
            }
            try self.settle();
            if (past) return;
        }
    }

    /// Stuck projectiles whose block was edited look at it again, and fall if it went.
    fn wake(self: *Projectiles) !void {
        if (self.woken == 0) return;
        var pass = store.Pass.init(&self.cache, store.under(.woken));
        var ids: [batch_max]u64 = undefined;
        while (true) {
            const count = try gather(&pass, &ids);
            if (count == 0) return;
            try self.hold(ids[0..count], false);
            for (self.held[0..self.held_count]) |*held| {
                // The mark goes with the waking.
                assert(held.projectile.loose);
                self.unmark(store.byId(.woken, held.projectile.id));
                self.woken -= 1;
                const projectile = held.projectile;
                projectile.loose = false;
                if (!projectile.in_ground) continue;
                const now = try self.blockAt(projectile.world, .{ @floatFromInt(projectile.stuck[0]), @floatFromInt(projectile.stuck[1]), @floatFromInt(projectile.stuck[2]) });
                if (now == projectile.stuck_state) continue;
                projectile.parked = false;
                self.fall(projectile);
            }
            try self.settle();
        }
    }

    /// The parked look over their viewers once a second, a twentieth of them a tick.
    fn visitParked(self: *Projectiles) !void {
        // A round since anyone moved, every parked arrow has looked since: nothing to find.
        if (self.now > self.moved_at + update_interval) return;
        var pass = store.Pass.init(&self.cache, store.parked(@intCast(self.now % update_interval), null));
        var ids: [batch_max]u64 = undefined;
        while (true) {
            const count = try gather(&pass, &ids);
            if (count == 0) return;
            try self.hold(ids[0..count], false);
            for (self.held[0..self.held_count]) |*held| {
                try self.forget(held);
                try self.meet(held);
            }
            try self.settle();
        }
    }

    /// PersistentProjectileEntity.tick, with TridentEntity's return before it.
    fn step(self: *Projectiles, held: *Held) !void {
        const projectile = held.projectile;
        if (projectile.shake > 0) projectile.shake -= 1;
        if (projectile.kind == .trident and projectile.in_ground_time > 4) projectile.dealt_damage = true;
        if (projectile.kind == .trident and projectile.loyalty > 0 and (projectile.dealt_damage or projectile.returning)) {
            try self.comeBack(projectile);
        } else {
            // A stuck one returns before ProjectileEntity.tick and Entity.baseTick.
            if (projectile.in_ground) return self.rest(projectile);
            projectile.in_ground_time = 0;
            // The water check, the water's slowing and the trace were done in section order; the
            // move is the motion the tick began with.
            const motion = self.motions[self.indexOf(held)];
            turn(projectile, motion, false);
            try self.move(projectile, self.traces[self.indexOf(held)], motion);
            if (projectile.removed) return;
            if (!projectile.in_water) scale(&projectile.velocity, air_drag);
            if (!projectile.in_ground) projectile.velocity[1] -= gravity;
        }
        if (!projectile.left_owner) projectile.left_owner = self.leftOwner(projectile);
        try self.baseTick(projectile);
    }

    /// Entity.baseTick after the move: the fire burns down, and what fell past the bottom of the
    /// world goes.
    fn baseTick(self: *Projectiles, projectile: *Projectile) !void {
        if (projectile.fire_ticks > 0) projectile.fire_ticks -= 1;
        if (projectile.position[1] < @as(f64, @floatFromInt((try self.heightOf(projectile.world)).minimum - 64))) projectile.removed = true;
    }

    /// Sleepers that may be asked to wake between two ticks before every sleeper wakes instead.
    const rousing_max = 4096;

    /// Asks the sleepers whose claims a box meets, horizontally grown by `reach`, to wake.
    fn rouseMeeting(self: *Projectiles, world: u32, box: projectile_claims.Box, reach: f64) void {
        // Asked to wake are woken by the next tick's rouse; past room for them, all are.
        if (self.claims.count == 0 or self.rouse_all) return;
        if (!self.claims.meeting(world, box, reach, self.rousing, &self.rousing_count)) self.rouse_all = true;
    }

    /// What may have moved since the last tick wakes the sleepers it came near: a mob or player
    /// in a claim might be hit, and a player moving near one might come to see it or stop. While
    /// projectiles fly nothing moves: a hit changes motion, which moves things on their own ticks.
    fn watch(self: *Projectiles) void {
        if (self.claims.count == 0) return;
        const mobs = self.deps.mobs;
        for (mobs.active.values()) |index| {
            const mob = &mobs.mobs[index];
            if (mob.removed) continue;
            const box = mobs.grid.boxes[index];
            self.rouseMeeting(mob.world, .{ .low = box.min, .high = box.max }, 0);
        }
        var moved = self.moved.iterator(.{});
        while (moved.next()) |slot| {
            const player = &self.deps.players.records[slot];
            const box = playerBox(player);
            self.rouseMeeting(player.world, .{ .low = box.min, .high = box.max }, tracking_blocks + 1);
        }
    }

    /// Which sleepers wake this tick, before the flying: those something came near and those
    /// due, sorted by id for the flying to take in order. After a restart, when no claim is left,
    /// every sleeper wakes and ticks from then on.
    fn rouse(self: *Projectiles) !void {
        self.waking_count = 0;
        defer {
            self.rousing_count = 0;
            self.rouse_all = false;
        }
        if (self.sleeping == 0) return;
        if (self.rouse_all) {
            assert(self.claims.count == 0);
            while (self.sleeping > 0) {
                var pass = store.Pass.init(&self.cache, store.under(.sleeping));
                const keys = try pass.next();
                if (keys.len == 0) return error.Corrupt;
                var ids: [batch_max]u64 = undefined;
                for (keys, ids[0..keys.len]) |key, *entity| entity.* = store.Key.id(key.slice());
                try self.wakeAll(ids[0..keys.len]);
            }
            return;
        }
        for (self.rousing[0..self.rousing_count]) |claim| {
            if (!self.claims.used(claim)) continue;
            self.waking[self.waking_count] = self.claims.remove(claim);
            self.waking_count += 1;
        }
        self.claims.takeDue(self.now, self.waking, &self.waking_count);
        std.mem.sortUnstable(u64, self.waking[0..self.waking_count], {}, std.sort.asc(u64));
    }


    /// A sleeper as it is at the end of the last tick. Woken when due, it is already: its record
    /// holds the state its sleep ends in. Woken early, it flies on from where it fell asleep.
    fn awaken(self: *const Projectiles, projectile: *Projectile) void {
        assert(projectile.asleep and self.now <= projectile.wake_at and self.now > projectile.slept_at);
        assert(!(projectile.synced and self.now == projectile.wake_at));
        projectile.asleep = false;
        const synced = projectile.synced;
        projectile.synced = false;
        if (self.now == projectile.wake_at and !synced) return;
        projectile.restart();
        var at = projectile.slept_at + 1;
        while (at < self.now) : (at += 1) drift(projectile);
    }

    /// Sleepers without claims, after a restart: each catches up and ticks from now on.
    fn wakeAll(self: *Projectiles, ids: []const u64) !void {
        try self.hold(ids, false);
        for (self.held[0..self.held_count]) |*held| {
            const projectile = held.projectile;
            // Only marked sleepers are queued.
            if (!projectile.asleep or !projectile.marked) return error.Corrupt;
            self.awaken(projectile);
            projectile.marked = false;
        }
        try self.settle();
    }

    /// Where a sleeper is after each tick, as `drift` would take it.
    const Motion = struct { position: [3]f64, velocity: [3]f64, yaw: f32, pitch: f32, shake: u8 };

    /// The states `drift` takes a projectile through, up to `ticks` of them or until it would
    /// fall past `floor`, worked out together: the motions first, as they do not depend on its
    /// facing, then every tick's facing at once, four to a vector, then the easing toward them.
    /// Each lane does what `turn` does alone, so the states are those of `drift` bit for bit.
    fn plan(projectile: *const Projectile, ticks: usize, floor: f64, out: *[update_interval + 1]Motion, low: *[3]f64, high: *[3]f64) usize {
        assert(ticks <= update_interval);
        const lanes = 4;
        const V = @Vector(lanes, f64);
        const P = @Vector(3, f64);
        // Each tick's motion as it begins, by axis, a vector's worth past the last.
        var xs: [update_interval + lanes]f64 = undefined;
        var ys: [update_interval + lanes]f64 = undefined;
        var zs: [update_interval + lanes]f64 = undefined;
        out[0] = .{ .position = projectile.position, .velocity = projectile.velocity, .yaw = projectile.yaw, .pitch = projectile.pitch, .shake = projectile.shake };
        var v = projectile.velocity;
        var at = projectile.position;
        var least: P = at;
        var most: P = at;
        var count: usize = 0;
        while (count < ticks) {
            const next: [3]f64 = .{ at[0] + v[0], at[1] + v[1], at[2] + v[2] };
            if (next[1] < floor) break;
            xs[count] = v[0];
            ys[count] = v[1];
            zs[count] = v[2];
            v = .{ v[0] * air_drag, v[1] * air_drag - gravity, v[2] * air_drag };
            at = next;
            out[count + 1].position = at;
            out[count + 1].velocity = v;
            least = @min(least, @as(P, at));
            most = @max(most, @as(P, at));
            count += 1;
        }
        low.* = least;
        high.* = most;
        // The lanes past the last are only filled, so the table is read in bounds.
        @memset(xs[count..][0..lanes], 0);
        @memset(ys[count..][0..lanes], 0);
        @memset(zs[count..][0..lanes], 0);
        var yaws: [update_interval + lanes]f32 = undefined;
        var pitches: [update_interval + lanes]f32 = undefined;
        const degrees: V = @splat(57.2957763671875);
        var first: usize = 0;
        while (first < count) : (first += lanes) {
            const x: V = xs[first..][0..lanes].*;
            const y: V = ys[first..][0..lanes].*;
            const z: V = zs[first..][0..lanes].*;
            const horizontal = @sqrt(x * x + z * z);
            const yaw: @Vector(lanes, f32) = @floatCast(mth.atan2Many(lanes, x, z) * degrees);
            const pitch: @Vector(lanes, f32) = @floatCast(mth.atan2Many(lanes, y, horizontal) * degrees);
            yaws[first..][0..lanes].* = yaw;
            pitches[first..][0..lanes].* = pitch;
        }
        for (0..count) |index| {
            out[index + 1].pitch = eased(out[index].pitch, pitches[index]);
            out[index + 1].yaw = eased(out[index].yaw, yaws[index]);
            out[index + 1].shake = out[index].shake -| 1;
        }
        return count;
    }

    /// One tick of a sleeper, as `trace`, `step` and `replicate` go with nothing near it: the
    /// shake wears off, it turns toward its motion, moves by it, and air and gravity slow it.
    fn drift(projectile: *Projectile) void {
        if (projectile.shake > 0) projectile.shake -= 1;
        projectile.in_ground_time = 0;
        const motion = projectile.velocity;
        turn(projectile, motion, false);
        for (&projectile.position, motion) |*axis, delta| axis.* += delta;
        scale(&projectile.velocity, air_drag);
        projectile.velocity[1] -= gravity;
    }

    /// After its tick, a flying projectile with nothing near its path until its next update
    /// sleeps until then: each tick's path is clear of blocks that affect it, no entity is within
    /// reach of the paths, no player's view of it changes, and nothing is owed to viewers. Its
    /// record takes the state its sleep ends in, and keeps where it began for an early wake.
    fn lull(self: *Projectiles, held: *Held) !void {
        const projectile = held.projectile;
        // Awake, `wake_at` is when it may next try: one that could not sleep tries again later.
        if (!self.sleep or self.now < projectile.wake_at) return;
        projectile.wake_at = self.now + retry_ticks;
        if (!moves(projectile) or (projectile.kind == .trident and projectile.loyalty > 0)) return;
        if (projectile.in_water or projectile.fire_ticks > 0 or !projectile.left_owner or projectile.impulse or projectile.data_changed) return;
        // It wakes by its next update tick at the latest, which ticks as any other.
        const until: u64 = @intCast(update_interval - @rem(self.age(projectile), update_interval));
        if (until < 3) return;
        const bounds = try self.heightOf(projectile.world);
        // Someone anywhere it could reach, and planning is not worth it: it moves at most its
        // speed a tick, and gravity a little more each tick.
        {
            const v = projectile.velocity;
            const t: f64 = @floatFromInt(until);
            const reach = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) * t + 0.025 * t * t + 1;
            const at = projectile.position;
            if (self.anyoneIn(projectile.world, claimed(.{ at[0] - reach, at[1] - reach, at[2] - reach }, .{ at[0] + reach, at[1] + reach, at[2] + reach }))) return;
        }
        // Its states tick by tick, as far as it stays above the void.
        var states: [update_interval + 1]Motion = undefined;
        var low: [3]f64 = undefined;
        var high: [3]f64 = undefined;
        // Through its update tick, if all of it is clear: then it wakes only to send the update.
        var ticks: u64 = plan(projectile, @intCast(until), @floatFromInt(bounds.minimum - 64), &states, &low, &high);
        const planned = ticks;
        // Clear all at once, most often; else as far as each tick's path is.
        if (!try self.clear(projectile.world, low, high)) {
            var clear_ticks: u64 = 0;
            while (clear_ticks < ticks and try self.clear(projectile.world, states[clear_ticks].position, states[clear_ticks + 1].position)) clear_ticks += 1;
            ticks = clear_ticks;
        }
        if (ticks < 2) return;
        // Seen alike by every player, most often by none near; else as far as it is.
        if (!self.unseenAround(projectile.world, low, high, held.row)) {
            var seen_ticks: u64 = 0;
            var ghost = projectile.*;
            while (seen_ticks < ticks) {
                ghost.position = states[seen_ticks + 1].position;
                if (!self.viewedAlike(held.row, &ghost)) break;
                seen_ticks += 1;
            }
            ticks = seen_ticks;
        }
        if (ticks < 2) return;
        // A shorter sleep passes through less.
        if (ticks != planned) {
            low = states[0].position;
            high = states[0].position;
            for (states[1 .. ticks + 1]) |*state| for (0..3) |axis| {
                low[axis] = @min(low[axis], state.position[axis]);
                high[axis] = @max(high[axis], state.position[axis]);
            };
        }
        const box = claimed(low, high);
        const synced = ticks == until;
        const wake_at = if (synced) self.now + until else self.now + ticks + 1;
        _ = self.claims.add(projectile.id, projectile.world, box, self.now, wake_at) orelse return;
        const end = &states[ticks];
        projectile.start_position = projectile.position;
        projectile.start_velocity = projectile.velocity;
        projectile.start_yaw = projectile.yaw;
        projectile.start_pitch = projectile.pitch;
        projectile.start_shake = projectile.shake;
        projectile.position = end.position;
        projectile.velocity = end.velocity;
        projectile.yaw = end.yaw;
        projectile.pitch = end.pitch;
        projectile.shake = end.shake;
        projectile.asleep = true;
        projectile.marked = true;
        projectile.slept_at = self.now;
        projectile.wake_at = wake_at;
        projectile.synced = synced;
    }

    /// Ticks between tries to sleep for a projectile that could not.
    const retry_ticks = 10;

    /// findTarget's swept box over paths within a box of positions, and a little more.
    fn claimed(low: [3]f64, high: [3]f64) projectile_claims.Box {
        const reach = half_width + 1 + 0.5;
        return .{
            .low = .{ low[0] - reach, low[1] - 1.5, low[2] - reach },
            .high = .{ high[0] + reach, high[1] + height + 1.5, high[2] + reach },
        };
    }

    /// Whether no player knows of a projectile, and none is close enough to see it anywhere in a
    /// box: then every place in it is seen alike, by no one.
    fn unseenAround(self: *Projectiles, world: u32, low: [3]f64, high: [3]f64, row: []const u64) bool {
        for (row) |word| if (word != 0) return false;
        if (self.players_near_tick != self.now) self.gatherPlayers();
        const reach = tracking_blocks + 1;
        for (self.players_near[0..self.players_near_count]) |near| {
            if (near.world != world and near.world != any_world) continue;
            // Far from the box around them all: far from each.
            if (low[0] - reach > near.high[0] or high[0] + reach < near.low[0] or low[2] - reach > near.high[1] or high[2] + reach < near.low[1]) return true;
            break;
        } else return true;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (player.world != world) continue;
            const dx = @max(low[0] - player.position.x, 0, player.position.x - high[0]);
            const dz = @max(low[2] - player.position.z, 0, player.position.z - high[2]);
            if (dx * dx + dz * dz <= reach * reach) return false;
        }
        return true;
    }

    /// The box around each world's players, worked out once a tick; with more worlds than room,
    /// the last stands for all the rest by covering everything.
    fn gatherPlayers(self: *Projectiles) void {
        self.players_near_tick = self.now;
        self.players_near_count = 0;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            const at: [2]f64 = .{ player.position.x, player.position.z };
            for (self.players_near[0..self.players_near_count]) |*near| {
                if (near.world != player.world) continue;
                near.low = .{ @min(near.low[0], at[0]), @min(near.low[1], at[1]) };
                near.high = .{ @max(near.high[0], at[0]), @max(near.high[1], at[1]) };
                break;
            } else if (self.players_near_count < players_near_max) {
                self.players_near[self.players_near_count] = .{ .world = player.world, .low = at, .high = at };
                self.players_near_count += 1;
            } else {
                // Out of room: everything counts as near, and each player is looked at.
                const last = &self.players_near[players_near_max - 1];
                last.world = any_world;
                last.low = @splat(-std.math.inf(f64));
                last.high = @splat(std.math.inf(f64));
            }
        }
    }

    const players_near_max = 8;
    const any_world = std.math.maxInt(u32);

    /// Whether players would see a projectile at a place as those who know of it now.
    fn viewedAlike(self: *Projectiles, row: []const u64, ghost: *const Projectile) bool {
        const near = self.viewersNear(ghost);
        for (row, near.always, near.maybe, 0..) |known, always, maybe, at| {
            var seen = always;
            var measured = maybe;
            while (measured != 0) : (measured &= measured - 1) {
                if (self.sees(at * 64 + @ctz(measured), ghost)) seen |= @as(u64, 1) << @intCast(@ctz(measured));
            }
            if (seen != known) return false;
        }
        return true;
    }

    /// Whether any mob or player is in a box.
    fn anyoneIn(self: *Projectiles, world: u32, box: projectile_claims.Box) bool {
        const mobs = self.deps.mobs;
        const within: body.Box = .{ .min = box.low, .max = box.high };
        if (mobs.active.values().len > 0) {
            var candidates = mobs.grid.query(world, .{ box.low[0] - mobs.widest_half, box.low[2] - mobs.widest_half }, .{ box.high[0] + mobs.widest_half, box.high[2] + mobs.widest_half });
            while (candidates.next()) |index| {
                if (mobs.grid.boxes[index].intersects(within)) return true;
            }
        }
        // Not near the box around a world's players: in no player's box.
        if (self.players_near_tick != self.now) self.gatherPlayers();
        for (self.players_near[0..self.players_near_count]) |near| {
            if (near.world != world and near.world != any_world) continue;
            if (box.low[0] - 1 > near.high[0] or box.high[0] + 1 < near.low[0] or box.low[2] - 1 > near.high[1] or box.high[2] + 1 < near.low[1]) return false;
            break;
        } else return false;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (player.world == world and playerBox(player).intersects(within)) return true;
        }
        return false;
    }

    /// Every projectile as it stands at the end of the tick, sleepers as their ticks would have
    /// left them, for a test to hold sleeping to ticking.
    pub fn digest(self: *Projectiles) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        var pass = store.Pass.init(&self.cache, store.under(.record));
        while (true) {
            const keys = try pass.next();
            if (keys.len == 0) break;
            var copies: [store.Pass.batch]store.Key = undefined;
            @memcpy(copies[0..keys.len], keys);
            for (copies[0..keys.len]) |key| {
                const lease = try self.cache.acquire(key.slice());
                defer lease.release();
                const bytes = lease.read() orelse return error.Corrupt;
                var projectile: Projectile = undefined;
                @memcpy(std.mem.asBytes(&projectile), bytes[0..@sizeOf(Projectile)]);
                // A sleeper holds the state it wakes in; before then, it is on its way there.
                // A sleeper holds the state its sleep ends in: after its last tick asleep, or
                // after its update tick when it sleeps through that too.
                const ends_at = if (!projectile.asleep) 0 else if (projectile.synced) projectile.wake_at else projectile.wake_at - 1;
                if (projectile.asleep and self.now < ends_at) {
                    projectile.restart();
                    var at = projectile.slept_at + 1;
                    while (at <= self.now) : (at += 1) drift(&projectile);
                }
                projectile.forgetSleep();
                // Field by field: padding holds whatever the bytes held.
                inline for (@typeInfo(Projectile).@"struct".field_names) |name| hasher.update(std.mem.asBytes(&@field(projectile, name)));
                hasher.update(bytes[@sizeOf(Projectile)..self.record_bytes]);
            }
        }
        return hasher.final();
    }

    pub fn sleepingCount(self: *const Projectiles) usize {
        return self.sleeping;
    }

    /// PersistentProjectileEntity's drags, floats widened as applyDrag(float) widens them.
    const air_drag: f64 = @as(f32, 0.99);
    const gravity: f64 = 0.05;

    fn waterDrag(projectile: *const Projectile) f64 {
        return if (projectile.kind == .trident) @as(f32, 0.99) else @as(f32, 0.6);
    }

    fn scale(velocity: *[3]f64, by: f64) void {
        for (velocity) |*axis| axis.* *= by;
    }

    /// The rotation a tick eases a fifth of the way toward the motion it began with, in float,
    /// with MathHelper.atan2; a returning trident faces back along it.
    fn turn(projectile: *Projectile, motion: [3]f64, back: bool) void {
        const horizontal = @sqrt(motion[0] * motion[0] + motion[2] * motion[2]);
        const yaw: f32 = @floatCast(if (back) mth.atan2(-motion[0], -motion[2]) * 57.2957763671875 else mth.atan2(motion[0], motion[2]) * 57.2957763671875);
        const pitch: f32 = @floatCast(mth.atan2(motion[1], horizontal) * 57.2957763671875);
        projectile.pitch = eased(projectile.pitch, pitch);
        projectile.yaw = eased(projectile.yaw, yaw);
    }

    /// ProjectileEntity.updateRotation.
    fn eased(last: f32, target: f32) f32 {
        var from = last;
        while (target - from < -180) from -= 360;
        while (target - from >= 180) from += 360;
        return mth.lerp(0.2, from, target);
    }

    /// Ticks since launch, as Entity.age counts them: stuck ones age too.
    fn age(self: *const Projectiles, projectile: *const Projectile) i64 {
        assert(self.now >= projectile.born_at);
        return @intCast(self.now - projectile.born_at);
    }

    fn indexOf(self: *const Projectiles, held: *const Held) usize {
        const index = (@intFromPtr(held) - @intFromPtr(self.held.ptr)) / @sizeOf(Held);
        assert(index < self.held_count);
        return index;
    }

    /// The reads of a batch's moves, in section order so the window holds what the next one
    /// needs: whether each is in water, which slows it first, and the first block in its path.
    /// They read alone, so their order changes nothing; the moves themselves go in tick order.
    fn trace(self: *Projectiles) !void {
        var count: usize = 0;
        for (self.held[0..self.held_count], 0..) |*held, index| {
            self.traces[index] = null;
            const projectile = held.projectile;
            if (held.quick or !moves(projectile)) continue;
            // The move is the motion the tick begins with; water slows only the next.
            const v = projectile.velocity;
            self.motions[index] = v;
            // Nothing that affects it around its path: no water to be in, no block to meet.
            const to: [3]f64 = .{ projectile.position[0] + v[0], projectile.position[1] + v[1], projectile.position[2] + v[2] };
            if (try self.clear(projectile.world, projectile.position, to)) {
                if (self.age(projectile) > 1) projectile.in_water = false;
                continue;
            }
            const at = projectile.position;
            const section: [3]i64 = .{ @divFloor(mth.floor(at[0]), 16), @divFloor(mth.floor(at[1]), 16), @divFloor(mth.floor(at[2]), 16) };
            self.order[count] = .{ .index = @intCast(index), .key = @as(u64, projectile.world) << 60 ^ @as(u64, @bitCast(section[0] & 0xfffff)) << 40 ^ @as(u64, @bitCast(section[2] & 0xfffff)) << 20 ^ @as(u64, @bitCast(section[1] & 0xfffff)) };
            count += 1;
        }
        std.mem.sortUnstable(Order, self.order[0..count], {}, Order.before);
        for (self.order[0..count]) |entry| {
            const projectile = self.held[entry.index].projectile;
            // Entity.baseTick's water state, which vanilla reads a tick later: not yet on the first.
            if (self.age(projectile) > 1) projectile.in_water = self.watery.isSet(try self.blockAt(projectile.world, projectile.position));
            const v = self.motions[entry.index];
            if (projectile.in_water) {
                projectile.fire_ticks = 0;
                scale(&projectile.velocity, waterDrag(projectile));
            }
            const from = projectile.position;
            const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
            self.traces[entry.index] = if (length > 0) try raycast.traceIn(&self.window, projectile.world, try self.heightOf(projectile.world), .{ .x = from[0], .y = from[1], .z = from[2] }, v, length) else null;
        }
    }

    /// A stuck trident counts its time in the ground, and falls if its block went.
    fn rest(self: *Projectiles, projectile: *Projectile) !void {
        projectile.in_ground_time += 1;
        if (projectile.loose) {
            projectile.loose = false;
            const now = try self.blockAt(projectile.world, .{ @floatFromInt(projectile.stuck[0]), @floatFromInt(projectile.stuck[1]), @floatFromInt(projectile.stuck[2]) });
            if (now != projectile.stuck_state) return self.fall(projectile);
        }
        // tickDespawn: a minute in the ground, unless a loyal trident waits for its owner.
        if (projectile.pickup == .allowed and projectile.loyalty > 0) return;
        projectile.life += 1;
        if (projectile.life >= 1200) projectile.removed = true;
    }

    /// AbstractArrow.startFalling.
    fn fall(self: *Projectiles, projectile: *Projectile) void {
        const random = self.random.random();
        projectile.in_ground = false;
        for (&projectile.velocity) |*axis| axis.* *= random.float(f64) * 0.2;
        projectile.life = 0;
        projectile.data_changed = true;
        projectile.impulse = true;
    }

    /// stepMoveAndHit: the nearest block in the path, and before it the nearest living thing,
    /// which a piercing arrow passes through to the next.
    fn move(self: *Projectiles, projectile: *Projectile, block: ?raycast.Hit, v: [3]f64) !void {
        const from = projectile.position;
        const end: [3]f64 = if (block) |hit| .{ hit.position.x, hit.position.y, hit.position.z } else .{ from[0] + v[0], from[1] + v[1], from[2] + v[2] };
        var start = from;
        var passes: usize = 0;
        while (passes < 8) : (passes += 1) {
            const target = self.findTarget(projectile, start, end) orelse break;
            projectile.position = target.at;
            const went_through = try self.hitTarget(projectile, target.target);
            projectile.impulse = true;
            if (projectile.removed or !went_through) return;
            start = target.at;
        }
        projectile.position = end;
        if (block) |hit| self.land(projectile, hit);
    }

    /// Runs an enchantment hook with the weapon a projectile came from, from its own slot.
    fn withWeapon(self: *Projectiles, projectile: *const Projectile, comptime hook: anytype, target_type: u32, amount: f32) !f32 {
        if (!projectile.has_weapon) return amount;
        const weapon = (try self.deps.inventories.get(.{ .owner = projectile.uuid, .index = 1 })).stack orelse return error.Corrupt;
        const pinned = try self.deps.items.acquire(weapon);
        defer pinned.release();
        self.scratch.reset();
        const attack = try attack_effects.Attack.start(.{
            .effects = &self.deps.enchantments.effects,
            .item_tags = &self.deps.items.deps.definitions.tags,
            .registries = &self.deps.client.client,
            .damage_type = if (projectile.kind == .trident) "minecraft:trident" else "minecraft:arrow",
            .attacker = &self.deps.players.records[projectile.owner],
            .direct_type = self.entity_types[@intFromEnum(projectile.kind)],
            .direct = false,
            .random = self.random.random(),
            .scratch = &self.scratch,
        });
        return hook(&attack, pinned.view, target_type, amount);
    }

    fn hitSound(projectile: *const Projectile) []const u8 {
        return switch (projectile.hit_sound) {
            .arrow => "minecraft:entity.arrow.hit",
            .crossbow => "minecraft:item.crossbow.hit",
        };
    }

    /// AbstractArrow.onHitBlock: it backs out of the face a little and stays.
    fn land(self: *Projectiles, projectile: *Projectile, hit: raycast.Hit) void {
        // It keeps the way it last faced.
        for (&projectile.position, projectile.velocity) |*axis, motion| axis.* -= @as(f64, @floatFromInt(std.math.sign(motion))) * 0.05000000074505806;
        projectile.velocity = @splat(0);
        projectile.in_ground = true;
        projectile.stuck = .{ hit.block.x, hit.block.y, hit.block.z };
        projectile.stuck_state = hit.state;
        projectile.shake = 7;
        projectile.landed_at = self.now;
        self.landed_at = self.now;
        projectile.critical = false;
        projectile.pierce = 0;
        projectile.pierced_count = 0;
        projectile.impulse = true;
        projectile.data_changed = true;
        const random = self.random.random();
        if (projectile.kind == .trident) self.sound(projectile, "minecraft:item.trident.hit_ground", 1, 1) else self.sound(projectile, hitSound(projectile), 1, 1.2 / (random.float(f32) * 0.2 + 0.9));
    }

    /// ThrownTrident's loyalty: it flies back to its owner's eyes through anything.
    fn comeBack(self: *Projectiles, projectile: *Projectile) !void {
        const owner = &self.deps.players.records[projectile.owner];
        const generation = if (owner.handle) |handle| handle.generation else 0;
        if (generation != projectile.owner_generation or owner.world != projectile.world or self.deps.player_states.of(owner).health <= 0) {
            projectile.removed = true;
            return;
        }
        if (!projectile.returning) {
            projectile.returning = true;
            self.sound(projectile, "minecraft:item.trident.return", 10, 1);
            projectile.in_ground = false;
            projectile.data_changed = true;
        }
        const loyalty: f64 = @floatFromInt(projectile.loyalty);
        const eye: [3]f64 = .{ owner.position.x, owner.position.y + 1.62, owner.position.z };
        const toward: [3]f64 = .{ eye[0] - projectile.position[0], eye[1] - projectile.position[1], eye[2] - projectile.position[2] };
        projectile.position[1] += toward[1] * 0.015 * loyalty;
        const unit = living.normalize(toward);
        for (&projectile.velocity, unit) |*axis, direction| axis.* = axis.* * 0.95 + direction * 0.05 * loyalty;
        // Then PersistentProjectileEntity.tick without clipping: it faces back along its motion,
        // passes through to where it leads, and air slows it, without gravity.
        const motion = projectile.velocity;
        projectile.in_ground_time = 0;
        if (projectile.in_water) scale(&projectile.velocity, waterDrag(projectile));
        turn(projectile, motion, true);
        for (&projectile.position, motion) |*axis, delta| axis.* += delta;
        if (!projectile.in_water) scale(&projectile.velocity, air_drag);
        projectile.impulse = true;
    }

    /// Who moved, joined or left since last tick.
    fn notice(self: *Projectiles) !void {
        self.moved.unsetAll();
        var forgotten: [max_row_bytes / 8]u64 = @splat(0);
        var any = false;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            const now: Seen = .{ .generation = if (player.handle) |handle| handle.generation else 0, .world = player.world, .position = .{ player.position.x, player.position.y, player.position.z }, .stage = @intFromEnum(player.stage), .gamemode = @intFromEnum(self.deps.player_states.of(player).gamemode) };
            if (std.meta.eql(now, self.seen[slot])) continue;
            // Another connection in the slot was sent nothing yet.
            if (now.generation != self.seen[slot].generation) {
                forgotten[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
                any = true;
            }
            self.seen[slot] = now;
            self.moved.set(slot);
            self.moved_at = self.now;
        }
        if (any) try self.unknown(forgotten[0..self.row_words]);
    }

    /// Players whose slots hold new connections know of no projectile. Like vanilla's tracker on
    /// a player's removal, it looks at every projectile: once a tick for all of them, a batch of
    /// records at a time.
    fn unknown(self: *Projectiles, forgotten: []const u64) !void {
        assert(forgotten.len == self.row_words);
        inline for (.{ store.Prefix.record, store.Prefix.removal }) |kind| {
            var pass = store.Pass.init(&self.cache, store.under(kind));
            while (true) {
                const keys = try pass.next();
                if (keys.len == 0) break;
                var slices: [store.Pass.batch][]const u8 = undefined;
                for (keys, slices[0..keys.len]) |*key, *slice| slice.* = key.slice();
                var leases: [store.Pass.batch]records.Cache.Lease = undefined;
                try self.cache.acquireMany(slices[0..keys.len], leases[0..keys.len]);
                defer for (leases[0..keys.len]) |lease| lease.release();
                const offset = if (kind == .record) @sizeOf(Projectile) else 8;
                for (leases[0..keys.len]) |lease| {
                    const length = (lease.read() orelse continue).len;
                    const value = lease.edit();
                    const row = std.mem.bytesAsSlice(u64, value[offset..][0 .. self.row_words * 8]);
                    for (row, forgotten) |*word, gone| word.* &= ~gone;
                    lease.commit(length);
                }
            }
        }
    }

    /// Player.touch and AbstractArrow.playerTouch: a player whose box, grown by (1, 0.5, 1),
    /// meets a stuck projectile that stopped shaking picks it up, if it may. A player who stood
    /// still finds nothing new, but while an arrow stops shaking.
    fn collect(self: *Projectiles) !void {
        const maturing = self.now <= self.landed_at + 7;
        for (self.deps.players.activeSlots()) |slot| {
            if (!maturing and !self.moved.isSet(slot)) continue;
            const player = &self.deps.players.records[slot];
            if (player.stage != .ready) continue;
            const state = self.deps.player_states.of(player);
            if (state.gamemode == .spectator or state.health <= 0) continue;
            const at = player.position;
            const reach: body.Box = .{ .min = .{ at.x - 1.3, at.y - 0.5, at.z - 1.3 }, .max = .{ at.x + 1.3, at.y + 2.3, at.z + 1.3 } };
            const low: [2]i32 = .{ mth.floor(reach.min[0] - half_width) >> store.cell_shift, mth.floor(reach.min[2] - half_width) >> store.cell_shift };
            const high: [2]i32 = .{ mth.floor(reach.max[0] + half_width) >> store.cell_shift, mth.floor(reach.max[2] + half_width) >> store.cell_shift };
            var x = low[0];
            while (x <= high[0]) : (x += 1) {
                var z = low[1];
                while (z <= high[1]) : (z += 1) {
                    if (self.cellEmpty(player.world, x, z)) continue;
                    try self.collectCell(slot, player.world, x, z, reach, state.gamemode == .creative);
                }
            }
        }
    }

    /// The stuck projectiles in one cell within a player's reach, a batch at a time.
    fn collectCell(self: *Projectiles, slot: usize, world_id: u32, x: i32, z: i32, reach: body.Box, creative: bool) !void {
        var pass = store.Pass.init(&self.cache, store.cell(world_id, x, z));
        var ids: [batch_max]u64 = undefined;
        while (true) {
            var count: usize = 0;
            while (count + store.Pass.batch <= ids.len) {
                const keys = try pass.next();
                if (keys.len == 0) break;
                for (keys) |key| {
                    const block = store.stuckBlock(key.slice());
                    if (@as(f64, @floatFromInt(block[1])) > reach.max[1] or @as(f64, @floatFromInt(block[1] + 1)) < reach.min[1]) continue;
                    ids[count] = store.Key.id(key.slice());
                    count += 1;
                }
            }
            if (count == 0) return;
            try self.hold(ids[0..count], false);
            for (self.held[0..self.held_count]) |*held| {
                const projectile = held.projectile;
                if (self.now < projectile.landed_at + 7 or !self.boxOf(projectile).intersects(reach)) continue;
                if (projectile.kind == .trident and projectile.owner != slot) continue;
                try self.take(slot, held, creative);
            }
            try self.settle();
        }
    }

    fn take(self: *Projectiles, slot: usize, held: *Held, creative: bool) !void {
        const projectile = held.projectile;
        switch (projectile.pickup) {
            .disallowed => return,
            .creative_only => if (!creative) return,
            // Inventory.add: all of it, or it stays.
            .allowed => {
                const stack = (try self.deps.inventories.get(.{ .owner = projectile.uuid, .index = 0 })).stack orelse return error.Corrupt;
                if (!try self.deps.menus.giveStack(slot, stack)) return;
            },
        }
        try self.queue(projectile.id, held.row, .update, false, packets.writeCollect, .{ networkId(projectile), entity_effects.playerId(slot), @as(i32, 1) });
        projectile.removed = true;
    }

    /// Removals a viewer had no room for are sent again; the gone are forgotten; those all told
    /// go.
    fn retire(self: *Projectiles) !void {
        if (self.removals == 0) return;
        var pass = store.Pass.init(&self.cache, store.under(.removal));
        while (true) {
            const keys = try pass.next();
            if (keys.len == 0) return;
            var copies: [store.Pass.batch]store.Key = undefined;
            @memcpy(copies[0..keys.len], keys);
            for (copies[0..keys.len]) |key| try self.retireOne(key);
        }
    }

    fn retireOne(self: *Projectiles, key: store.Key) !void {
        const lease = try self.cache.acquire(key.slice());
        defer lease.release();
        const value = lease.edit();
        const network = std.mem.readInt(i32, value[0..4], .little);
        const row = std.mem.bytesAsSlice(u64, value[8..][0 .. self.row_words * 8]);
        var any = false;
        for (row, 0..) |*word, at| {
            word.* &= ~self.goneIn(at);
            any = any or word.* != 0;
        }
        lease.commit(8 + self.row_words * 8);
        if (!any) {
            lease.remove();
            self.removals -= 1;
            return;
        }
        for (self.audience, row) |*audience, word| audience.* = word;
        try self.queue(store.Key.id(key.slice()), self.audience, .remove, true, packets.writeRemove, .{network});
    }

    /// The players in a word of a row who have gone, whom nothing can be sent to.
    fn goneIn(self: *const Projectiles, word: usize) u64 {
        var gone: u64 = 0;
        for (0..64) |bit| {
            const other = word * 64 + bit;
            if (other >= self.deps.players.records.len) break;
            const player = &self.deps.players.records[other];
            if (player.handle == null or player.stage != .ready) gone |= @as(u64, 1) << @intCast(bit);
        }
        return gone;
    }

    /// ServerEntity for projectiles: who sees one is told of it once, then of its state when
    /// it changes and where it is when it was pushed or every second.
    fn replicate(self: *Projectiles, held: *Held) !void {
        try self.forget(held);
        try self.meet(held);
        try self.updates(held);
    }

    /// Viewers out of range, or gone, are told it is. Those out of range of all of the chunk go
    /// by whole words; only those in range of part of it are measured. A viewer stays known
    /// until it has taken the removal.
    fn forget(self: *Projectiles, held: *Held) !void {
        const projectile = held.projectile;
        const near = self.viewersNear(projectile);
        var any = false;
        for (held.row, near.always, near.maybe, self.leaving, 0..) |word, always, maybe, *leaving, at| {
            leaving.* = word & ~(always | maybe);
            var measured = word & maybe;
            while (measured != 0) : (measured &= measured - 1) {
                if (!self.sees(at * 64 + @ctz(measured), projectile)) leaving.* |= @as(u64, 1) << @intCast(@ctz(measured));
            }
            any = any or leaving.* != 0;
        }
        if (any) try self.queue(projectile.id, self.leaving, .remove, false, packets.writeRemove, .{networkId(projectile)});
    }

    /// Players newly in range are sent it, its spawn and its data. Those in range of all of the
    /// chunk join by whole words, and projectiles joining the same players share a batch.
    fn meet(self: *Projectiles, held: *Held) !void {
        const projectile = held.projectile;
        const near = self.viewersNear(projectile);
        var any = false;
        for (held.row, near.always, near.maybe, self.joining, self.starved, 0..) |word, always, maybe, *joining, starved, at| {
            joining.* = always & ~word;
            var measured = maybe & ~word;
            while (measured != 0) : (measured &= measured - 1) {
                if (self.sees(at * 64 + @ctz(measured), projectile)) joining.* |= @as(u64, 1) << @intCast(@ctz(measured));
            }
            // Viewers out of room this tick get it on a later one.
            joining.* &= ~starved;
            any = any or joining.* != 0;
        }
        if (!any) return;
        const spawn: packets.Spawn = .{ .id = networkId(projectile), .uuid = projectile.uuid, .kind = self.entity_types[@intFromEnum(projectile.kind)], .position = projectile.position, .velocity = projectile.velocity, .yaw = angle(projectile.yaw), .pitch = angle(projectile.pitch), .owner = entity_effects.playerId(projectile.owner) };
        try self.queueSpawn(projectile.id, self.joining, spawn, self.dataOf(projectile));
    }

    /// Changes of state and position, for the viewers who have room this tick; a client that
    /// misses one simulates on and takes the next.
    fn updates(self: *Projectiles, held: *Held) !void {
        const projectile = held.projectile;
        const due = @rem(self.age(projectile), update_interval) == 0;
        const moving = projectile.impulse or (due and !projectile.in_ground);
        if (!projectile.data_changed and !moving) return;
        for (self.audience, held.row, self.starved) |*audience, known, starved| audience.* = known & ~starved;
        if (projectile.data_changed) try self.queue(projectile.id, self.audience, .update, false, packets.writeData, .{ networkId(projectile), self.dataOf(projectile) });
        projectile.data_changed = false;
        if (!moving) return;
        try self.queue(projectile.id, self.audience, .update, false, packets.writeSync, .{ networkId(projectile), projectile.position, projectile.velocity, projectile.yaw, projectile.pitch, projectile.in_ground });
        projectile.impulse = false;
    }

    /// What a queued packet does for its viewers once they take it.
    const Purpose = enum { spawn, update, remove };
    const Pending = struct { id: u64, kind: Purpose, removal: bool, receipt: sessions.Service.Broadcast.Receipt };

    /// Queues a packet for some of a projectile's viewers, as ItemReplication batches its own:
    /// packets for the same viewers go in one batch, admitted for all of them at once. What each
    /// viewer took is read back when the batch goes, so the known rows say what clients have.
    fn queue(self: *Projectiles, entity: u64, audience: []const u64, kind: Purpose, removal: bool, comptime writer: anytype, arguments: anytype) !void {
        self.traceSend(entity, audience, @intFromEnum(kind));
        if (!try self.prepare(audience, 1)) return;
        const receipt = self.deps.players.deps.packets.broadcast(&self.outbox, writer, null, null, arguments, 128) catch |err| switch (err) {
            error.Backpressured => return self.backlog(),
            else => return err,
        };
        self.record(entity, kind, removal, receipt);
    }

    /// A spawn and its entity data as one group, which each viewer takes whole or not at all.
    /// What projectiles ask to send, for runs to be compared by; whether viewers take it is the
    /// sessions' affair.
    fn traceSend(self: *Projectiles, entity: u64, audience: []const u64, kind: u8) void {
        if (!self.tracing) return;
        var hasher = std.hash.Wyhash.init(self.sent);
        hasher.update(std.mem.asBytes(&self.now));
        hasher.update(std.mem.asBytes(&entity));
        hasher.update(&.{kind});
        // Not who: that waits on viewers having room, which wall time decides.
        _ = audience;
        self.sent = hasher.final();
    }

    fn queueSpawn(self: *Projectiles, entity: u64, audience: []const u64, spawn: packets.Spawn, data: packets.Data) !void {
        self.traceSend(entity, audience, 255);
        // Two packets and the bundle around them.
        if (!try self.prepare(audience, 4)) return;
        const receipt = self.deps.players.deps.packets.broadcastGroup(&self.outbox, .{ .{ packets.spawnLegacy, packets.spawnPacked }, packets.writeData }, null, null, .{ .{spawn}, .{ spawn.id, data } }, &.{ 128, 128 }) catch |err| switch (err) {
            error.Backpressured => return self.backlog(),
            else => return err,
        };
        self.record(entity, .spawn, false, receipt);
    }

    fn record(self: *Projectiles, entity: u64, kind: Purpose, removal: bool, receipt: sessions.Service.Broadcast.Receipt) void {
        self.outbox_pending[self.outbox_count] = .{ .id = entity, .kind = kind, .removal = removal, .receipt = receipt };
        self.queued[@intFromEnum(kind)] += 1;
        self.outbox_count += 1;
    }

    /// Sends the batch and reads back who took each packet: spawns become known, removals
    /// forgotten, and a removal no viewer is left to take goes.
    fn flush(self: *Projectiles) !void {
        const outbox = &self.outbox;
        if (!outbox.active) return;
        outbox.commit();
        defer {
            outbox.cancel();
            self.outbox_count = 0;
        }
        for (self.outbox_pending[0..self.outbox_count]) |pending| {
            var unsupported = outbox.unsupported(pending.receipt).iterator();
            while (unsupported.next()) |index| self.deps.players.deps.sessions.disconnect(outbox.handleAt(index));
            if (outbox.accepted(pending.receipt).count() > 0) self.taken[@intFromEnum(pending.kind)] += 1;
            // Whoever did not take it gets it on a later tick, and nothing more new this one.
            if (pending.kind != .update and outbox.accepted(pending.receipt).count() < outbox.recipients) self.starve(pending.receipt);
            if (pending.kind != .update) try self.acknowledge(pending);
        }
    }

    /// Marks who took a spawn or a removal in the row it belongs to: of a projectile in hand, of
    /// one in the cache, or of a removal owed.
    fn acknowledge(self: *Projectiles, pending: Pending) !void {
        if (!pending.removal) for (self.held[self.held_settled..self.held_count]) |*held| {
            if (held.projectile.id == pending.id) return self.apply(pending, held.row);
        };
        if (!pending.removal) {
            const lease = try self.cache.acquire(store.byId(.record, pending.id).slice());
            defer lease.release();
            if (lease.read() != null) {
                const value = lease.edit();
                self.apply(pending, std.mem.bytesAsSlice(u64, value[@sizeOf(Projectile)..self.record_bytes]));
                return lease.commit(self.record_bytes);
            }
        }
        // A projectile gone since: its removal is owed to whoever took the spawn too.
        const lease = try self.cache.acquire(store.byId(.removal, pending.id).slice());
        defer lease.release();
        if (lease.read() == null) return;
        const value = lease.edit();
        const row = std.mem.bytesAsSlice(u64, value[8..][0 .. self.row_words * 8]);
        self.apply(pending, row);
        lease.commit(8 + self.row_words * 8);
        for (row) |word| if (word != 0) return;
        lease.remove();
        self.removals -= 1;
    }

    fn apply(self: *Projectiles, pending: Pending, row: anytype) void {
        var accepted = self.outbox.accepted(pending.receipt).iterator();
        while (accepted.next()) |other| {
            const bit = @as(u64, 1) << @intCast(other % 64);
            switch (pending.kind) {
                .spawn => row[other / 64] |= bit,
                .remove => row[other / 64] &= ~bit,
                .update => unreachable,
            }
        }
    }

    /// A chunk's shared players, the last one asked for first.
    fn lookup(self: *Projectiles, column: Column) ?Range {
        const kind = @intFromEnum(column.nearness);
        if (self.last_columns[kind]) |last| if (std.meta.eql(last, column)) return self.last_ranges[kind];
        const range = self.columns.get(column) orelse return null;
        self.last_columns[kind] = column;
        self.last_ranges[kind] = range;
        return range;
    }

    /// How many projectiles are in the world, flying or stuck.
    pub fn activeCount(self: *const Projectiles) usize {
        return @intCast(self.count);
    }

    /// How many tick: those flying, and tridents.
    pub fn tickingCount(self: *const Projectiles) usize {
        return @intCast(self.ticking);
    }

    fn entityType(name: []const u8) !u32 {
        return @intCast(registry.entityId(name) orelse return error.UnknownEntity);
    }

    /// Water, and the blocks that hold it.
    /// Blocks without a collision shape that still do something to a projectile inside them.
    /// Erring towards more only costs time: their space is looked at block by block.
    const affecting_blocks = [_][]const u8{
        "minecraft:water",           "minecraft:lava",             "minecraft:bubble_column",
        "minecraft:fire",            "minecraft:soul_fire",        "minecraft:cobweb",
        "minecraft:nether_portal",   "minecraft:end_portal",       "minecraft:end_gateway",
        "minecraft:tripwire",        "minecraft:powder_snow",      "minecraft:sweet_berry_bush",
        "minecraft:wither_rose",     "minecraft:kelp",             "minecraft:kelp_plant",
        "minecraft:seagrass",        "minecraft:tall_seagrass",    "minecraft:pointed_dripstone",
        "minecraft:scaffolding",     "minecraft:light",            "minecraft:structure_void",
    };

    pub const affecting: u8 = 1;

    fn affectingStates(allocator: std.mem.Allocator) ![]u8 {
        const states = try allocator.alloc(u8, registry.block_state_names.len);
        for (registry.block_state_names, states, 0..) |name, *property, state| {
            const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
            const block = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
            const special = for (affecting_blocks) |listed| {
                if (std.mem.eql(u8, block, listed)) break true;
            } else false;
            const pressing = std.mem.endsWith(u8, block, "_pressure_plate") or std.mem.endsWith(u8, block, "_button");
            const wet = std.mem.indexOf(u8, name, "waterlogged=true") != null;
            property.* = if (shape.count > 0 or special or pressing or wet) affecting else 0;
        }
        return states;
    }

    fn wetStates(allocator: std.mem.Allocator) !std.DynamicBitSetUnmanaged {
        var set = try std.DynamicBitSetUnmanaged.initEmpty(allocator, registry.block_state_names.len);
        for (registry.block_state_names, 0..) |name, state| {
            const wet = std.mem.startsWith(u8, name, "minecraft:water[") or std.mem.indexOf(u8, name, "waterlogged=true") != null or
                std.mem.startsWith(u8, name, "minecraft:bubble_column") or std.mem.startsWith(u8, name, "minecraft:kelp") or std.mem.indexOf(u8, name, "seagrass") != null;
            if (wet) set.set(state);
        }
        return set;
    }

    /// Projectile.shoot's rotation: it faces the way it moves.
    fn face(projectile: *Projectile) void {
        const v = projectile.velocity;
        const horizontal = @sqrt(v[0] * v[0] + v[2] * v[2]);
        projectile.yaw = @floatCast(mth.atan2(v[0], v[2]) * 57.2957763671875);
        projectile.pitch = @floatCast(mth.atan2(v[1], horizontal) * 57.2957763671875);
    }

    /// Projectile.getMovementToShoot: the direction with a little spread, at a speed.
    pub fn aim(self: *Projectiles, direction: [3]f64, speed: f64, inaccuracy: f64) [3]f64 {
        const unit = living.normalize(direction);
        const random = self.random.random();
        var result: [3]f64 = undefined;
        for (0..3) |axis| result[axis] = (unit[axis] + 0.0172275 * inaccuracy * (random.float(f64) - random.float(f64))) * speed;
        return result;
    }

    /// Whether a projectile moves this tick, rather than resting or flying home.
    fn moves(projectile: *const Projectile) bool {
        if (projectile.in_ground) return false;
        return !(projectile.kind == .trident and projectile.loyalty > 0 and (projectile.dealt_damage or projectile.returning));
    }

    const Target = union(enum) { mob: u32, player: usize };
    const Found = struct { target: Target, at: [3]f64 };

    /// ProjectileUtil.getEntityHitResult: the living things whose boxes, grown by the margin a
    /// projectile gains as it flies, the path from `from` to `to` enters, the nearest first.
    fn findTarget(self: *Projectiles, projectile: *const Projectile, from: [3]f64, to: [3]f64) ?Found {
        // In float, as vanilla grows boxes by it.
        const margin: f64 = @max(@as(f32, 0), @min(@as(f32, 0.3), @as(f32, @floatFromInt(self.age(projectile) - 2)) / 20.0));
        const low: [3]f64 = .{ @min(from[0], to[0]) - half_width - 1, @min(from[1], to[1]) - 1, @min(from[2], to[2]) - half_width - 1 };
        const high: [3]f64 = .{ @max(from[0], to[0]) + half_width + 1, @max(from[1], to[1]) + height + 1, @max(from[2], to[2]) + half_width + 1 };
        const swept: body.Box = .{ .min = low, .max = high };
        var best: ?Found = null;
        var best_distance = std.math.inf(f64);
        const mobs = self.deps.mobs;
        // No mobs, no grid to look in.
        var candidates = mobs.grid.query(projectile.world, .{ low[0] - mobs.widest_half, low[2] - mobs.widest_half }, .{ high[0] + mobs.widest_half, high[2] + mobs.widest_half });
        while (mobs.active.values().len > 0) {
            const index = candidates.next() orelse break;
            const mob = &mobs.mobs[index];
            if (mob.removed or !mob.alive() or !mobs.grid.boxes[index].intersects(swept) or self.pierced(projectile, mob.id)) continue;
            const distance = clip(grown(living.box(mobs, mob), margin), from, to) orelse continue;
            if (distance < best_distance) {
                best_distance = distance;
                best = .{ .target = .{ .mob = index }, .at = along(from, to, distance) };
            }
        }
        // A path longer than a chunk looks for itself; a shorter one shares its chunk's players.
        const far = high[0] - low[0] > 15 or high[2] - low[2] > 15;
        if (far) {
            var players = self.deps.players.nearby(projectile.world, .{ .x = (low[0] + high[0]) / 2, .y = 0, .z = (low[2] + high[2]) / 2 }, @intFromFloat(@ceil((high[0] - low[0] + high[2] - low[2]) / 32) + 1));
            while (players.next()) |other| {
                const box = playerBox(&self.deps.players.records[other]);
                if (!box.intersects(swept) or !self.canHitPlayer(projectile, other)) continue;
                self.nearer(&best, &best_distance, .{ .player = other }, box, margin, from, to);
            }
            return best;
        }
        // The players a chunk shares, ruled out at once when the path misses the box around them
        // all; they are known to be playing and alive.
        const shared = self.targetsNear(projectile);
        const bounds = shared.bounds orelse return best;
        if (!bounds.intersects(swept)) return best;
        for (shared.players, shared.boxes) |other, box| {
            if (!box.intersects(swept) or !self.mayHit(projectile, other)) continue;
            self.nearer(&best, &best_distance, .{ .player = other }, box, margin, from, to);
        }
        return best;
    }

    fn nearer(_: *const Projectiles, best: *?Found, best_distance: *f64, target: Target, box: body.Box, margin: f64, from: [3]f64, to: [3]f64) void {
        const distance = clip(grown(box, margin), from, to) orelse return;
        if (distance >= best_distance.*) return;
        best_distance.* = distance;
        best.* = .{ .target = target, .at = along(from, to, distance) };
    }

    /// Projectile.canHitEntity for a player: alive, playing, not its owner before it left, and
    /// one the owner may harm.
    fn canHitPlayer(self: *Projectiles, projectile: *const Projectile, other: usize) bool {
        const player = &self.deps.players.records[other];
        if (player.world != projectile.world or player.stage != .ready or player.handle == null) return false;
        const state = self.deps.player_states.of(player);
        if (state.gamemode == .spectator or state.health <= 0) return false;
        return self.mayHit(projectile, other);
    }

    /// The rest of canHitEntity for a player who is playing: not its owner before it left, one
    /// the owner may harm, and not one it pierced already.
    fn mayHit(self: *const Projectiles, projectile: *const Projectile, other: usize) bool {
        if (other == projectile.owner and !projectile.left_owner) return false;
        if (other != projectile.owner and !self.deps.damage.configuration.pvp) return false;
        return !self.pierced(projectile, @as(u64, @intCast(other + 1)) << 48);
    }

    fn pierced(_: *const Projectiles, projectile: *const Projectile, key: u64) bool {
        return std.mem.indexOfScalar(u64, projectile.pierced[0..projectile.pierced_count], key) != null;
    }

    /// AbstractArrow.onHitEntity and ThrownTrident's: the hit and what follows it. Returns
    /// whether the projectile goes on through, as a piercing arrow does.
    fn hitTarget(self: *Projectiles, projectile: *Projectile, target: Target) !bool {
        const key: u64 = switch (target) {
            .mob => |index| self.deps.mobs.mobs[index].id,
            .player => |other| @as(u64, @intCast(other + 1)) << 48,
        };
        if (projectile.pierce > 0) {
            if (projectile.pierced_count >= projectile.pierce + 1) {
                projectile.removed = true;
                return false;
            }
            projectile.pierced[projectile.pierced_count] = key;
            projectile.pierced_count += 1;
        }
        const amount = try self.damageAmount(projectile, target);
        const landed = try self.hurt(projectile, target, amount);
        if (projectile.kind == .trident) {
            projectile.dealt_damage = true;
            self.reverse(projectile);
            for (&projectile.velocity, [3]f64{ 0.02, 0.2, 0.02 }) |*axis, factor| axis.* *= factor;
            self.sound(projectile, "minecraft:item.trident.hit", 1, 1);
            return false;
        }
        if (!landed) {
            self.reverse(projectile);
            for (&projectile.velocity) |*axis| axis.* *= 0.2;
            const v = projectile.velocity;
            if (v[0] * v[0] + v[1] * v[1] + v[2] * v[2] < 1.0e-7) projectile.removed = true;
            return false;
        }
        try self.knockback(projectile, target);
        const random = self.random.random();
        self.sound(projectile, hitSound(projectile), 1, 1.2 / (random.float(f32) * 0.2 + 0.9));
        if (projectile.pierce == 0) projectile.removed = true;
        return projectile.pierce > 0;
    }

    /// The damage of a hit: an arrow's grows with its speed and a critical one's by chance; a
    /// trident's is its own. Power and Impaling come from the weapon.
    fn damageAmount(self: *Projectiles, projectile: *const Projectile, target: Target) !f32 {
        const base: f32 = if (projectile.kind == .trident) 8.0 else 2.0;
        const target_type = switch (target) {
            .mob => |index| self.deps.mobs.traits(self.deps.mobs.mobs[index].species).entity_type,
            .player => self.player_type,
        };
        const enchanted = try self.withWeapon(projectile, struct {
            fn call(attack: *const attack_effects.Attack, weapon: ?item_data.View, kind: u32, amount: f32) !f32 {
                return attack.damage(weapon, kind, amount);
            }
        }.call, target_type, base);
        if (projectile.kind == .trident) return enchanted;
        const v = projectile.velocity;
        const speed: f32 = @floatCast(@sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
        var dealt: i64 = @intFromFloat(@ceil(std.math.clamp(speed * enchanted, 0, 2147483647.0)));
        if (projectile.critical) dealt = @min(dealt + self.random.random().intRangeLessThan(i64, 0, @divTrunc(dealt, 2) + 2), std.math.maxInt(i32));
        return @floatFromInt(dealt);
    }

    fn hurt(self: *Projectiles, projectile: *Projectile, target: Target, amount: f32) !bool {
        const owner = projectile.owner;
        const v = projectile.velocity;
        const damage_type: @import("mob.zig").DamageType = if (projectile.kind == .trident) .trident else .arrow;
        switch (target) {
            .mob => |index| {
                const mob = &self.deps.mobs.mobs[index];
                if (projectile.fire_ticks > 0) self.deps.mobs.ignite(mob, 5);
                // The push follows the projectile's motion, as calculateHorizontalHurtKnockbackDirection.
                return self.deps.mobs.hurt(mob, .{ .type = damage_type, .attacker = @intCast(owner), .source = .{ mob.position[0] - v[0], mob.position[1], mob.position[2] - v[2] } }, amount);
            },
            .player => |other| {
                if (projectile.fire_ticks > 0) try self.deps.damage.ignite(other, 5);
                const cause = entity_effects.playerId(owner) + 1;
                return self.deps.damage.hurt(other, .{ .type = damage_type, .attacker = owner, .cause_id = cause, .direct_id = networkId(projectile) + 1, .knockback = .{ v[0], v[2] }, .piercing = projectile.pierce > 0 }, amount);
            },
        }
    }

    /// AbstractArrow.doKnockback: Punch pushes along the flight.
    fn knockback(self: *Projectiles, projectile: *Projectile, target: Target) !void {
        const kind = switch (target) {
            .mob => |index| self.deps.mobs.traits(self.deps.mobs.mobs[index].species).entity_type,
            .player => self.player_type,
        };
        const strength = try self.withWeapon(projectile, struct {
            fn call(attack: *const attack_effects.Attack, weapon: ?item_data.View, target_type: u32, amount: f32) !f32 {
                return attack.knockback(weapon, target_type, amount);
            }
        }.call, kind, 0);
        if (strength <= 0) return;
        const v = projectile.velocity;
        const flat = living.normalize(.{ v[0], 0, v[2] });
        switch (target) {
            .mob => |index| {
                const mob = &self.deps.mobs.mobs[index];
                const resistance = self.deps.mobs.traits(mob.species).attribute(.knockback_resistance);
                const push = @as(f64, strength) * 0.6 * @max(0, 1 - resistance);
                mob.velocity = .{ mob.velocity[0] + flat[0] * push, mob.velocity[1] + 0.1, mob.velocity[2] + flat[2] * push };
                mob.has_impulse = true;
            },
            .player => |other| try self.deps.damage.knockback(other, @as(f64, strength) * 0.6, -flat[0], -flat[2]),
        }
    }

    /// ProjectileDeflection.REVERSE: back the way it came, turned about.
    fn reverse(self: *Projectiles, projectile: *Projectile) void {
        for (&projectile.velocity) |*axis| axis.* *= -0.5;
        projectile.yaw += 170 + self.random.random().float(f32) * 20;
    }

    /// checkLeftOwner: the owner's box, grown by one, no longer meets the swept box.
    fn leftOwner(self: *Projectiles, projectile: *const Projectile) bool {
        const owner = &self.deps.players.records[projectile.owner];
        const at = owner.position;
        const box: body.Box = .{ .min = .{ at.x - 0.3, at.y, at.z - 0.3 }, .max = .{ at.x + 0.3, at.y + 1.8, at.z + 0.3 } };
        const own = self.boxOf(projectile);
        const v = projectile.velocity;
        const swept: body.Box = .{
            .min = .{ @min(own.min[0], own.min[0] + v[0]) - 1, @min(own.min[1], own.min[1] + v[1]) - 1, @min(own.min[2], own.min[2] + v[2]) - 1 },
            .max = .{ @max(own.max[0], own.max[0] + v[0]) + 1, @max(own.max[1], own.max[1] + v[1]) + 1, @max(own.max[2], own.max[2] + v[2]) + 1 },
        };
        return owner.world != projectile.world or !swept.intersects(box);
    }

    fn boxOf(_: *const Projectiles, projectile: *const Projectile) body.Box {
        const at = projectile.position;
        return .{ .min = .{ at[0] - half_width, at[1], at[2] - half_width }, .max = .{ at[0] + half_width, at[1] + height, at[2] + half_width } };
    }

    /// One block, through the tick's shared window.
    fn blockAt(self: *Projectiles, world: u32, at: [3]f64) !u16 {
        const position: chunks.Position = .{ .x = mth.floor(at[0]), .y = mth.floor(at[1]), .z = mth.floor(at[2]) };
        if (!(try self.heightOf(world)).contains(position.y)) return self.air_state;
        var view: [1]chunks.View = undefined;
        try self.window.readMany(&.{chunks.sectionAt(world, position)}, &view);
        return view[0].get(chunks.localIndex(position));
    }

    /// Whether no block of 4x4x4 within a block of the box from `from` to `to` holds anything that
    /// affects a projectile: then a trace between them meets nothing and neither end is in water.
    fn clear(self: *Projectiles, world: u32, from: [3]f64, to: [3]f64) !bool {
        var low: [3]i32 = undefined;
        var high: [3]i32 = undefined;
        for (0..3) |axis| {
            const a = @min(from[axis], to[axis]);
            const b = @max(from[axis], to[axis]);
            // Far or strange paths are looked at block by block.
            if (!std.math.isFinite(a) or !std.math.isFinite(b) or b - a > 128 or @abs(a) > 30_000_000 or @abs(b) > 30_000_000) return false;
            low[axis] = mth.floor(a) - 1;
            high[axis] = mth.floor(b) + 1;
        }
        const bounds = try self.heightOf(world);
        var sy = low[1] >> 4;
        while (sy <= high[1] >> 4) : (sy += 1) {
            if (sy * 16 >= bounds.maximum or sy * 16 + 15 < bounds.minimum) continue;
            var sx = low[0] >> 4;
            while (sx <= high[0] >> 4) : (sx += 1) {
                var sz = low[2] >> 4;
                while (sz <= high[2] >> 4) : (sz += 1) {
                    const section: chunks.Section = .{ .world = world, .x = sx, .y = sy, .z = sz };
                    const wanted = blocksWithin(section, low, high);
                    if (wanted & try self.occupancy(section) != 0) return false;
                }
            }
        }
        return true;
    }

    /// The blocks of 4x4x4 of a section that a box of cells reaches.
    fn blocksWithin(section: chunks.Section, low: [3]i32, high: [3]i32) u64 {
        const base: [3]i32 = .{ section.x * 16, section.y * 16, section.z * 16 };
        var span: [3][2]u6 = undefined;
        for (0..3) |axis| {
            span[axis] = .{ @intCast(@divFloor(@max(low[axis] - base[axis], 0), 4)), @intCast(@divFloor(@min(high[axis] - base[axis], 15), 4)) };
        }
        const row = (@as(u64, 0xf) >> @intCast(3 - (span[0][1] - span[0][0]))) << span[0][0];
        var result: u64 = 0;
        var y = span[1][0];
        while (y <= span[1][1]) : (y += 1) {
            var z = span[2][0];
            while (z <= span[2][1]) : (z += 1) result |= row << (y * 16 + z * 4);
        }
        return result;
    }

    /// A section's blocks of 4x4x4 that hold what affects projectiles, read once until edited.
    fn occupancy(self: *Projectiles, section: chunks.Section) !u64 {
        if (self.space.get(section)) |mask| return mask;
        var view: [1]chunks.View = undefined;
        try self.window.readMany(&.{section}, &view);
        const mask = try chunks.occupancy.of(view[0], self.affecting_states, affecting);
        self.space.put(section, mask);
        return mask;
    }

    fn heightOf(self: *Projectiles, world: u32) !raycast.Height {
        if (self.height_world == world) return self.world_height;
        const dimension = (self.deps.worlds.get(world) orelse return error.UnknownWorld).dimension;
        const minimum = dimension.minimumSection() * 16;
        self.world_height = .{ .minimum = minimum, .maximum = minimum + @as(i32, @intCast(dimension.sectionCount() * 16)) };
        self.height_world = world;
        return self.world_height;
    }

    /// Whether a player is within tracking range of a projectile.
    fn sees(self: *const Projectiles, other: usize, projectile: *const Projectile) bool {
        const viewer = &self.deps.players.records[other];
        const dx = viewer.position.x - projectile.position[0];
        const dz = viewer.position.z - projectile.position[2];
        return viewer.world == projectile.world and viewer.stage == .ready and viewer.handle != null and dx * dx + dz * dz <= tracking_blocks * tracking_blocks;
    }

    /// viewers: who sees into the chunk. targets: who may be hit by anything flying through it.
    const Nearness = enum { viewers, targets };
    const Viewers = struct { always: []const u64, maybe: []const u64 };

    fn columnOf(projectile: *const Projectile, nearness: Nearness) Column {
        return .{ .world = projectile.world, .x = mth.floor(projectile.position[0] / 16), .z = mth.floor(projectile.position[2] / 16), .nearness = nearness };
    }

    /// Who sees into a projectile's chunk, found once a tick for every projectile in it: those
    /// in range of all of it, and those in range of some of it. Past the shared rows, each
    /// projectile finds its own.
    fn viewersNear(self: *Projectiles, projectile: *const Projectile) Viewers {
        const column = columnOf(projectile, .viewers);
        const words = self.row_words;
        if (self.lookup(column)) |range| return .{ .always = self.masks[range.start..][0..words], .maybe = self.masks[range.start + words ..][0..words] };
        const shared = self.mask_count + 2 * words <= self.masks.len;
        const start = if (shared) self.mask_count else self.masks.len - 2 * words;
        const rows = self.masks[start..][0 .. 2 * words];
        self.classify(column, rows[0..words], rows[words..]);
        if (shared) {
            self.mask_count += 2 * words;
            self.columns.putAssumeCapacity(column, .{ .start = @intCast(start), .len = @intCast(2 * words) });
        }
        return .{ .always = rows[0..words], .maybe = rows[words..] };
    }

    /// Sorts the players near a chunk by how much of it is within their tracking range.
    fn classify(self: *Projectiles, column: Column, always: []u64, maybe: []u64) void {
        @memset(always, 0);
        @memset(maybe, 0);
        const low: [2]f64 = .{ @as(f64, @floatFromInt(column.x)) * 16, @as(f64, @floatFromInt(column.z)) * 16 };
        // Four chunks of range, and one more for anywhere in this chunk.
        var nearby = self.deps.players.nearby(column.world, .{ .x = low[0] + 8, .y = 0, .z = low[1] + 8 }, 5);
        while (nearby.next()) |other| {
            const viewer = &self.deps.players.records[other];
            if (viewer.world != column.world or viewer.stage != .ready or viewer.handle == null) continue;
            const at: [2]f64 = .{ viewer.position.x, viewer.position.z };
            var nearest: f64 = 0;
            var farthest: f64 = 0;
            for (at, low) |point, start| {
                const near = @max(start - point, 0, point - (start + 16));
                const far = @max(@abs(point - start), @abs(point - (start + 16)));
                nearest += near * near;
                farthest += far * far;
            }
            const bit = @as(u64, 1) << @intCast(other % 64);
            if (farthest <= tracking_blocks * tracking_blocks) {
                always[other / 64] |= bit;
            } else if (nearest <= tracking_blocks * tracking_blocks) maybe[other / 64] |= bit;
        }
    }

    /// The players a projectile flying through its chunk may hit: in the world, playing and
    /// alive, found once a tick for every projectile there.
    fn targetsNear(self: *Projectiles, projectile: *const Projectile) Targets {
        const column = columnOf(projectile, .targets);
        if (self.lookup(column)) |range| return self.targetsOf(range);
        const players = self.deps.players.records.len;
        if (self.candidate_count + players > self.candidates.len) {
            const count = self.eligible(column, self.overflow, self.overflow_boxes);
            return .{ .players = self.overflow[0..count], .boxes = self.overflow_boxes[0..count], .bounds = around(self.overflow_boxes[0..count]) };
        }
        const start = self.candidate_count;
        const count = self.eligible(column, self.candidates[start..][0..players], self.candidate_boxes[start..][0..players]);
        self.candidate_count += count;
        const range: Range = .{ .start = @intCast(start), .len = @intCast(count), .bounds = around(self.candidate_boxes[start..][0..count]) orelse undefined };
        self.columns.putAssumeCapacity(column, range);
        return self.targetsOf(range);
    }

    fn targetsOf(self: *const Projectiles, range: Range) Targets {
        return .{ .players = self.candidates[range.start..][0..range.len], .boxes = self.candidate_boxes[range.start..][0..range.len], .bounds = if (range.len == 0) null else range.bounds };
    }

    /// The players within a chunk of a chunk who may be hit, the farthest a path through it
    /// shorter than a chunk reaches.
    fn eligible(self: *Projectiles, column: Column, output: []u32, boxes: []body.Box) usize {
        var count: usize = 0;
        var nearby = self.deps.players.nearby(column.world, .{ .x = @as(f64, @floatFromInt(column.x)) * 16 + 8, .y = 0, .z = @as(f64, @floatFromInt(column.z)) * 16 + 8 }, 1);
        while (nearby.next()) |other| {
            const player = &self.deps.players.records[other];
            if (player.world != column.world or player.stage != .ready or player.handle == null) continue;
            const state = self.deps.player_states.of(player);
            if (state.gamemode == .spectator or state.health <= 0) continue;
            assert(count < output.len);
            output[count] = @intCast(other);
            boxes[count] = playerBox(player);
            count += 1;
        }
        return count;
    }

    fn dataOf(_: *const Projectiles, projectile: *const Projectile) packets.Data {
        return .{
            .critical = projectile.critical,
            .pierce = projectile.pierce,
            .in_ground = projectile.in_ground,
            .trident = if (projectile.kind == .trident) .{ .loyalty = projectile.loyalty, .foil = projectile.foil } else null,
        };
    }

    /// The viewers in the batch who did not take a packet are starved for the rest of the tick.
    fn starve(self: *Projectiles, receipt: sessions.Service.Broadcast.Receipt) void {
        self.moved_at = self.now;
        const accepted = self.outbox.accepted(receipt);
        for (self.outbox_audience, 0..) |word, at| {
            var bits = word;
            while (bits != 0) : (bits &= bits - 1) {
                const other = at * 64 + @ctz(bits);
                if (!accepted.contains(other)) self.starved[at] |= @as(u64, 1) << @intCast(@ctz(bits));
            }
        }
    }

    /// The batch for an audience, begun if the one open is for others or full. False if nothing
    /// can go, to no one or to no room.
    fn prepare(self: *Projectiles, audience: []const u64, entries: usize) !bool {
        assert(audience.len == self.row_words);
        const outbox = &self.outbox;
        const needed = entries * self.deps.players.deps.sessions.config.protocols.len;
        if (outbox.active and (!std.mem.eql(u64, audience, self.outbox_audience) or self.outbox_count == sessions.Service.batch_max or outbox.count + needed > outbox.entries.len)) try self.flush();
        if (!outbox.active) {
            var count: usize = 0;
            for (audience, 0..) |word, at| {
                var bits = word;
                while (bits != 0) : (bits &= bits - 1) {
                    const player = &self.deps.players.records[at * 64 + @ctz(bits)];
                    if (player.handle == null or player.stage != .ready) continue;
                    self.recipients[count] = .{ .handle = player.handle.?, .protocol = player.protocol };
                    count += 1;
                }
            }
            if (count == 0) return false;
            outbox.begin(self.recipients[0..count]) catch |err| switch (err) {
                // Nothing went: a spawn is tried again next tick, a removal on its next retry.
                error.Backpressured => {
                    self.backlog();
                    return false;
                },
                else => return err,
            };
            @memcpy(self.outbox_audience, audience);
        }
        return true;
    }

    /// The batch's viewers had no room: parked arrows keep looking over their viewers until all
    /// are told, and those viewers are sent no more spawns this tick.
    fn backlog(self: *Projectiles) void {
        self.moved_at = self.now;
        for (self.starved, self.outbox_audience) |*starved, audience| starved.* |= audience;
    }

    fn sound(self: *Projectiles, projectile: *const Projectile, name: []const u8, volume: f32, pitch: f32) void {
        self.effects.sound(projectile.world, .{ .x = projectile.position[0], .y = projectile.position[1], .z = projectile.position[2] }, name, .neutral, volume, pitch, @bitCast(self.random.next()), null);
    }

};


/// Projectiles take negative network ids, as mobs and items do.
fn networkId(projectile: *const Projectile) i32 {
    return -@as(i32, @intCast(projectile.id));
}

fn angle(value: f32) i8 {
    return @bitCast(@as(u8, @intFromFloat(@mod(@floor(@as(f64, value) * 256.0 / 360.0), 256.0))));
}

/// A player's box: 0.6 wide, 1.8 tall, or 1.5 sneaking.
fn playerBox(player: *const @import("players").player_state.Player) body.Box {
    const at = player.position;
    const height_: f64 = if (player.flags.sneaking) 1.5 else 1.8;
    return .{ .min = .{ at.x - 0.3, at.y, at.z - 0.3 }, .max = .{ at.x + 0.3, at.y + height_, at.z + 0.3 } };
}

/// The box around boxes, or none for none.
fn around(boxes: []const body.Box) ?body.Box {
    if (boxes.len == 0) return null;
    var result = boxes[0];
    for (boxes[1..]) |box| for (0..3) |axis| {
        result.min[axis] = @min(result.min[axis], box.min[axis]);
        result.max[axis] = @max(result.max[axis], box.max[axis]);
    };
    return result;
}

fn grown(box: body.Box, margin: f64) body.Box {
    return .{ .min = .{ box.min[0] - margin, box.min[1] - margin, box.min[2] - margin }, .max = .{ box.max[0] + margin, box.max[1] + margin, box.max[2] + margin } };
}

fn along(from: [3]f64, to: [3]f64, fraction: f64) [3]f64 {
    return .{ from[0] + (to[0] - from[0]) * fraction, from[1] + (to[1] - from[1]) * fraction, from[2] + (to[2] - from[2]) * fraction };
}

/// AABB.clip: where along the path from `from` to `to`, as a fraction, it enters the box. A
/// path that starts inside never enters.
fn clip(box: body.Box, from: [3]f64, to: [3]f64) ?f64 {
    var enter: f64 = 0;
    var leave: f64 = 1;
    for (0..3) |axis| {
        const delta = to[axis] - from[axis];
        if (delta == 0) {
            if (from[axis] < box.min[axis] or from[axis] > box.max[axis]) return null;
            continue;
        }
        const a = (box.min[axis] - from[axis]) / delta;
        const b = (box.max[axis] - from[axis]) / delta;
        enter = @max(enter, @min(a, b));
        leave = @min(leave, @max(a, b));
        if (enter > leave) return null;
    }
    if (enter <= 0) return null;
    return enter;
}

test "a path enters a box where its slabs meet, and not from inside" {
    const box: body.Box = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), clip(box, .{ -1, 0.5, 0.5 }, .{ 3, 0.5, 0.5 }).?, 1e-12);
    try std.testing.expect(clip(box, .{ 0.5, 0.5, 0.5 }, .{ 3, 0.5, 0.5 }) == null);
    try std.testing.expect(clip(box, .{ -1, 2, 0.5 }, .{ 3, 2, 0.5 }) == null);
}

