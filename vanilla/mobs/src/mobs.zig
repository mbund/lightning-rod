//! The mobs of every world, in memory with the places they stand, ticked in vanilla's order
//! where the ticking domain reaches and saved at checkpoints. Mobs read blocks through the
//! levels every body shares.

const std = @import("std");
const game_data = @import("game_data");
const chunks = @import("chunks");
const entities = @import("entities");
const records = @import("records");
const storage = @import("storage");
const lightning_rod = @import("lightning_rod");
const minecraft = @import("minecraft_model");
const worlds = @import("worlds");
const Blocks = @import("vanilla_content").blocks.Blocks;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const Domains = @import("domains").domains.Domains;
const world_effects = @import("vanilla_blocks").world_effects;
const body = @import("vanilla_bodies").body;
const EntityCollisions = @import("vanilla_bodies").entity_collisions.EntityCollisions;
const Levels = @import("vanilla_bodies").levels.Levels;
const BlockEdits = @import("vanilla_bodies").block_edits.BlockEdits;
const PlayerRecord = @import("players").player_state.Player;
const living = @import("living.zig");
const mth = @import("vanilla_bodies").mth;
const content_tags = @import("vanilla_content").content_tags;
const mob_tick = @import("mob_tick.zig");
const mob_blocks = @import("vanilla_bodies").mob_blocks;
const species_data = @import("species.zig");
const mob_state = @import("mob.zig");
const JavaRandom = @import("vanilla_bodies").java_random.JavaRandom;
const pathfinding = @import("pathfinding.zig");
const navigation = @import("navigation.zig");
const herd_state = @import("herd.zig");
const mob_extras = @import("extras.zig");
const goals = @import("goals.zig");
const inventories = @import("inventories");
const Lighting = @import("terrain").lighting.Lighting;
const LightSample = @import("terrain").lighting.Sample;
const Time = @import("vanilla_world").time.Time;
const Weather = @import("vanilla_world").weather.Weather;
const Items = @import("vanilla_items").items.Items;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const Experience = @import("vanilla_survival").experience.Experience;
const damage_types = @import("vanilla_survival").damage_types;
const DamageTypes = damage_types.DamageTypes;
const Loot = @import("vanilla_items").loot_registry.Loot;
const loot = @import("vanilla_items").loot;
const item_data = @import("vanilla_items").item_data;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const Furnaces = @import("vanilla_crafting").furnaces.Furnaces;
const EnchantmentRegistry = @import("vanilla_items").enchantment_registry.EnchantmentRegistry;
const damage = @import("damage.zig");

const Mob = mob_state.Mob;
const Boats = @import("boats.zig").Boats;
const MobState = mob_state.MobState;
const Species = mob_state.Species;
const assert = std.debug.assert;

/// Sounds mobs make, by vanilla's sound event names.
pub const Sound = enum {
    generic_small_fall,
    generic_big_fall,
    generic_swim,
    generic_splash,
    generic_burn,
    generic_extinguish_fire,
    generic_eat,
    honey_block_slide,
    cow_ambient,
    cow_hurt,
    cow_death,
    cow_step,
    cow_milk,
    amethyst_block_chime,
    turtle_egg_break,

    pub fn name(self: Sound) []const u8 {
        return switch (self) {
            .generic_small_fall => "minecraft:entity.generic.small_fall",
            .generic_big_fall => "minecraft:entity.generic.big_fall",
            .generic_swim => "minecraft:entity.generic.swim",
            .generic_splash => "minecraft:entity.generic.splash",
            .generic_burn => "minecraft:entity.generic.burn",
            .generic_extinguish_fire => "minecraft:entity.generic.extinguish_fire",
            .generic_eat => "minecraft:entity.generic.eat",
            .honey_block_slide => "minecraft:block.honey_block.slide",
            .cow_ambient => "minecraft:entity.cow.ambient",
            .cow_hurt => "minecraft:entity.cow.hurt",
            .cow_death => "minecraft:entity.cow.death",
            .cow_step => "minecraft:entity.cow.step",
            .cow_milk => "minecraft:entity.cow.milk",
            .amethyst_block_chime => "minecraft:block.amethyst_block.chime",
            .turtle_egg_break => "minecraft:entity.turtle.egg_break",
        };
    }
};

pub const Mobs = struct {
    pub const id = "minecraft:mobs";

    pub const Configuration = struct {
        /// Events held for the replication between its ticks; past them, it sends them early.
        events: usize = 1024,
        /// Block edits held for paths to answer in a batch, from the first that changes a
        /// collision. When they fill, the paths answer them at once.
        edits: u32 = 16384,
        seed: u64 = 0x6d6f6273,
    };

    pub const Dependencies = struct {
        chunks: *chunks.Chunks,
        worlds: *worlds.Worlds,
        block_definitions: *Blocks,
        dimensions: *Dimensions,
        players: *Players,
        player_states: *PlayerStates,
        world_border: *WorldBorder,
        domains: *Domains,
        entities: *entities.Entities,
        record_workspaces: *records.Workspaces,
        storage: storage.Space,
        lighting: *Lighting,
        time: *Time,
        weather: *Weather,
        items: *Items,
        inventories: *inventories.Inventories,
        client: *ClientRegistries,
        experience: *Experience,
        damage_types: *DamageTypes,
        loot: *Loot,
        dropped: *ItemEntities,
        furnaces: *Furnaces,
        enchantment_registry: *EnchantmentRegistry,
        collisions: *EntityCollisions,
        levels: *Levels,
        block_edits: *BlockEdits,
    };

    deps: Dependencies,
    config: Configuration,
    /// Every mob's components, a row each in the mobs' table, in the tick order's sequence, each
    /// component a column: `inSlot` gives where a mob's records lie, good until the tick's end.
    rows: Table,
    cow_type: u32,
    /// Where every entity is, by section and in the order each came into its own, as vanilla's
    /// entity sections keep them, and the order they tick in: shared by every kind.
    places: *entities.Places,
    /// What lookups of mobs are after, among every kind in the space.
    kinds: entities.Kinds,
    /// The places' ticking columns as mobs last learned their places in the order.
    /// Half the width of the widest mob, and the height of the tallest, which a box query
    /// reaches out by from the places of mobs' feet.
    widest_half: f64,
    tallest: f64,
    /// Mobs' rare parts, behind their rows' links.
    extras: mob_extras.Store,
    /// Mobs in memory, by their directory slots.
    active: entities.pool.IndexSet,
    /// Every mob's slot in the order replication sends them, as `collectOrder` last found.
    ordered: entities.Array(u32),
    /// The classes of blocks, as the levels have them.
    blocks: *mob_blocks.MobBlocks,
    species: [@typeInfo(Species).@"enum".field_names.len]species_data.Traits,
    /// The level's random, which a few block reactions draw from.
    level_random: JavaRandom,
    /// Seeds for new mobs' randoms, as RandomSupport.generateUniqueSeed gives each entity its own.
    seeds: std.Random.DefaultPrng,
    /// Seeds of sound packets, which vanilla draws from a separate random that nothing else reads.
    sound_seeds: std.Random.DefaultPrng,
    effects: world_effects.Effects,
    table: records.Table,
    /// Whether every kept mob was brought in at once, where nothing follows the loaded domain.
    loaded_all: bool = false,
    air_state: u16,
    /// The working memory of path searches, one at a time on the simulation thread.
    search: pathfinding.Search,
    /// The nodes of the paths mobs are following, each path a blob in the entities' pool, and
    /// a path's nodes read whole while its navigation works on them.
    path_nodes: entities.extras.Blobs,
    path_work: []pathfinding.PathNode,
    /// Edits since the first that changed a collision, which paths answer in a batch, in order.
    edits: []body.Edit,
    edit_count: usize = 0,
    /// While held edits are answered early: the rest of the section being told of, which the
    /// world shows already.
    later: ?Later = null,
    /// Times the held edits filled and were answered early, for measuring.
    edits_answered_early: u64 = 0,
    /// What went wrong answering edits early, inside a notification, told at the next tick.
    failure: ?anyerror = null,
    /// What befell mobs since the replication last sent it, in order.
    events: []mob_state.Event,
    event_count: usize = 0,
    /// Sends the events at once, when they fill within a tick; without it, as with no
    /// replication, nobody hears and they are let go.
    events_full: ?EventsFull = null,
    /// The boats, which mobs push and collide with, once they start.
    boats: ?*Boats = null,
    /// The boxes the last move collided with but blocks.
    /// Path searches run, and recomputations edits asked for, for measuring.
    path_searches: u64 = 0,
    edit_recomputes: u64 = 0,
    /// Travels resting mobs skipped, and travels run, for measuring.
    travels_skipped: u64 = 0,
    travels_run: u64 = 0,
    /// Ticks idle mobs took in the herd, for measuring.
    idle_ticks: u64 = 0,
    /// Blocks of idle mobs, one per lane, advanced together, and lanes in them left to the scalar tick.
    idle_blocks: u64 = 0,
    rare_lanes: u64 = 0,
    /// Blocks as they stood after the edit being answered, which levels read while it is set.
    overlay: body.Overlay,
    overlay_view: ?*const body.Overlay = null,
    /// The blocks around the awake mob ticking, which levels read while it is set.
    window: body.Window = .{},
    window_view: ?*const body.Window = null,
    effects_scratch: @import("block_effects.zig").Scratch = .{},
    /// By player slot, whether the player holds cow food in either hand, noted as mobs start
    /// ticking: tempting asks every other tick for every mob, and hands change only between.
    holding_food: []bool,
    /// The players idle mobs look for this tick.
    present: []herd_state.Audience.Player,
    present_count: usize = 0,
    holders: []herd_state.Audience.Player,
    holder_count: usize = 0,
    /// Set while Debug checks an idle tick against the full one, which then plays no sound.
    muted: bool = false,
    /// Rises whenever columns start or stop ticking.
    domain_revision: u64 = 0,
    /// Worlds' levels found this tick, kept only while mobs tick.
    views: [8]WorldView = undefined,
    view_count: usize = 0,
    ticking: bool = false,
    /// Entity.movementThisTick for the mob ticking, which only it adds to and reads.
    movements: [8]mob_state.Movement = undefined,
    /// While entities tick: the players idle mobs look for and what they know of their kind.
    context: TickContext = undefined,
    /// What a goal's canUse chose, which its start takes up at once: a place to go, a mob, or
    /// a player.
    chosen: struct { target: [3]f64 = .{ 0, 0, 0 }, partner: ?u64 = null, player: ?u32 = null } = .{},
    /// The last path found, until a navigation takes it.
    scratch_path: []pathfinding.PathNode,
    scratch: struct { count: u16 = 0, target: [3]i32 = .{ 0, 0, 0 }, reached: bool = false } = .{},
    /// The cow_food item tag and the panic_causes damage type tag, read when definitions change.
    food_tag: ?content_tags.Tags.Id = null,
    /// Loot tables draw from their own random, as each vanilla table has its own sequence.
    loot_random: std.Random.DefaultPrng,
    loot_scratch: std.heap.FixedBufferAllocator,
    /// By damage type: what its tags say, and its id in the registry.
    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Mobs {
        const self = try allocate(allocator, config, deps);
        try self.migrate();
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Mobs {
        if (config.edits == 0) return error.InvalidEditCapacity;
        const self = try allocator.create(Mobs);
        const pool = &deps.entities.pool;
        const cow_type: u32 = @intCast(game_data.registry.entityId("minecraft:cow").?);
        self.* = .{
            .deps = deps,
            .config = config,
            .rows = try .init(allocator, pool, &deps.entities.directory),
            .cow_type = cow_type,
            .places = &deps.entities.places,
            .kinds = .{},
            .widest_half = 0,
            .tallest = 0,
            .active = try .init(allocator, pool),
            .extras = try .init(allocator, pool),
            .ordered = try .init(allocator, pool),
            .blocks = deps.levels.blocks,
            .species = undefined,
            .level_random = .init(@bitCast(config.seed)),
            .seeds = .init(config.seed ^ 0x73656564),
            .sound_seeds = .init(config.seed ^ 0x736f756e64),
            .loot_random = .init(config.seed ^ 0x6c6f6f74),
            .loot_scratch = .init(try allocator.alloc(u8, 16 * 1024)),
            .effects = try .init(allocator, deps.players),
            .table = records.Table.init(deps.storage, deps.record_workspaces.resources),
            .air_state = @intCast(game_data.registry.blockStateId("minecraft:air").?),
            .search = try .init(allocator, search_nodes),
            .path_nodes = try .init(allocator, pool),
            .path_work = try allocator.alloc(pathfinding.PathNode, path_capacity),
            .scratch_path = try allocator.alloc(pathfinding.PathNode, path_capacity),
            .edits = try allocator.alloc(body.Edit, config.edits),
            .events = try allocator.alloc(mob_state.Event, config.events),
            .holding_food = try allocator.alloc(bool, deps.players.records.len),
            .present = try allocator.alloc(herd_state.Audience.Player, deps.players.records.len),
            .holders = try allocator.alloc(herd_state.Audience.Player, deps.players.records.len),
            .overlay = try .init(allocator, config.edits + chunks.edit_previous_max),
        };
        try self.readTags();
        try deps.items.deps.definitions.registry.onChange(self, readTags);
        try deps.chunks.observe(.init(self, blocksChanged));
        try deps.domains.observe(.init(Mobs, self, domainsChanged));
        try deps.client.registry.onChange(self, readTags);
        inline for (@typeInfo(Species).@"enum".field_names, 0..) |field, index| self.species[index] = species_data.traits(@field(Species, field));
        for (self.species) |species| self.kinds.bits.set(species.entity_type);
        // Each species tracks at its own range, as EntityType clientTrackingRange says.
        for (self.species) |species| try deps.entities.declare(.{ .kinds = .of(&.{species.entity_type}), .tracking_range = @as(u32, species.tracking_range) * 16 });
        for (self.species) |species| try deps.entities.addTable(species.entity_type, &self.rows.core);
        // Mobs take their turns in the one tick order, as many as fill a pass's run.
        try deps.entities.addTicker(.init(Mobs, self, self.kinds, entities.Entities.run_max));
        try deps.entities.addColumnHolder(.init(Mobs, self, loadColumn, unloadColumn));
        // How mobs and players meet others, living bodies both: pushable, which vehicles collide
        // with and what pushes, and pickable.
        try deps.collisions.register(self.kinds, .{ .context = self, .pushable = mobPushable, .pickable = mobPickable, .position = mobPosition, .nudge = mobNudge, .touched = mobTouched });
        try deps.collisions.register(.of(&.{Players.entityKind()}), .{ .context = self, .pushable = playerPushable, .pickable = playerPickable, .position = playerPosition });
        for (self.species) |species| {
            self.widest_half = @max(self.widest_half, @as(f64, species.width) / 2);
            self.tallest = @max(self.tallest, @as(f64, species.height));
        }
        return self;
    }

    pub fn traits(self: *const Mobs, species: Species) *const species_data.Traits {
        return &self.species[@backingInt(species)];
    }

    pub fn level(self: *Mobs, world: u32) body.Level {
        var result = self.view(world).level;
        result.overlay = self.overlay_view;
        result.window = self.window_view;
        return result;
    }

    pub fn ultrawarm(self: *Mobs, world: u32) bool {
        return self.view(world).ultrawarm;
    }

    /// A world's level and dimension facts, found once a tick, as definitions change only
    /// between ticks.
    fn view(self: *Mobs, world: u32) *const WorldView {
        for (self.views[0..self.view_count]) |*known| if (known.world == world) return known;
        const definition = self.deps.worlds.get(world).?;
        const dimension = self.deps.dimensions.get(definition.dimension.name);
        const made: WorldView = .{
            .world = world,
            .level = self.deps.levels.level(world),
            .ultrawarm = if (dimension) |found| found.ultrawarm else false,
        };
        // Outside the tick nothing is kept, and more worlds than places only means finding one again.
        const at = if (!self.ticking) 0 else if (self.view_count < self.views.len) self.view_count else self.views.len - 1;
        if (self.ticking) self.view_count = @max(self.view_count, at + 1);
        self.views[at] = made;
        return &self.views[at];
    }

    fn tickViews(self: *Mobs, ticking: bool) void {
        self.view_count = 0;
        self.ticking = ticking;
    }

    pub fn levelRandom(self: *Mobs) *JavaRandom {
        return &self.level_random;
    }

    /// The mobGriefing game rule, which this server keeps at vanilla's default.
    pub fn mobGriefing(_: *const Mobs) bool {
        return true;
    }

    pub const Spawn = struct {
        species: Species,
        world: u32,
        position: [3]f64,
        yaw: f32,
        baby: bool = false,
        variant: u8 = 0,
        /// Mob.finalizeSpawn, which spawning from eggs and commands runs and breeding does not.
        finalize: bool = true,
    };

    /// Adds a mob as EntityType.create and Mob.finalizeSpawn leave it, at a position.
    pub fn spawn(self: *Mobs, request: Spawn) !u64 {
        const entity = try self.deps.entities.reserveIds(1);
        var random = entityRandom(self.config.seed, entity);
        const traits_entry = self.traits(request.species);
        var created: MobState = .{
            .entity = .{
                .id = entity,
                .uuid = randomUuid(&random),
                .species = request.species,
            },
            .idle = .{
                .random = random,
                .head_yaw = request.yaw,
                .body_yaw = request.yaw,
            },
            .motion = .{
                .world = request.world,
                .position = request.position,
                .old_position = request.position,
                .yaw = request.yaw,
                .old_yaw = request.yaw,
            },
            .living = .{
                .health = @floatCast(traits_entry.attribute(.max_health)),
            },
            .cow = .{ .variant = request.variant },
        };
        if (request.finalize) {
            // Mob.finalizeSpawn: a random bonus to the follow range, then the left hand chance.
            created.living.follow_range_bonus = self.level_random.triangle(0.0, 0.11485000000000001);
            created.control.left_handed = self.level_random.nextFloat() < 0.05;
        } else {
            // LivingEntity's constructor turns the head by Math.random in radians, read as degrees,
            // and snapTo leaves it while the body faces the given yaw.
            created.idle.head_yaw = @floatCast(@as(f64, @floatFromInt(self.seeds.next() >> 11)) / (1 << 53) * @as(f64, @as(f32, std.math.pi * 2.0)));
        }
        if (request.baby) created.idle.age = -24000;
        return self.insert(created);
    }

    /// Entity.random, which vanilla seeds anew for each entity. Seeded by the entity id, which
    /// no two mobs share across restarts, it draws each a UUID of its own, as clients keep only
    /// the first entity with a UUID.
    fn entityRandom(seed: u64, entity: u64) JavaRandom {
        return .init(@bitCast(std.hash.int(seed ^ entity)));
    }

    fn randomUuid(random: *JavaRandom) u128 {
        // UUID.randomUUID, a version 4 identifier, from the entity's own random.
        var bytes: u128 = (@as(u128, @as(u64, @bitCast(random.nextLong()))) << 64) | @as(u64, @bitCast(random.nextLong()));
        bytes &= ~(@as(u128, 0xf000) << 64);
        bytes |= @as(u128, 0x4000) << 64;
        bytes &= ~(@as(u128, 0xc000_0000_0000_0000));
        bytes |= @as(u128, 0x8000_0000_0000_0000);
        return bytes;
    }

    fn insert(self: *Mobs, created: MobState) !u64 {
        const held = self.deps.entities;
        // A mob's slot is its directory slot.
        const index = try held.enter(created.entity.id, self.traits(created.entity.species).entity_type);
        errdefer held.leave(index);
        // Dormant until placed: the tick order gives it its place in `locate`.
        try self.rows.add(index, rowOf(created), true);
        errdefer self.rows.remove(index);
        try self.extras.write(self.rows.ref(index).field("extras"), created.rare);
        try self.active.insert(index);
        try self.locate(index);
        // A mob appearing touches the mobs around it.
        const placed = living.box(self, try self.inSlot(index));
        self.wake(created.motion.world, placed.min, placed.max);
        return created.entity.id;
    }

    /// Keeps a mob's place where it stands: into a new section it comes last, and removed it
    /// leaves its section, as vanilla's entity sections hear of every move at once.
    pub fn locate(self: *Mobs, index: u32) !void {
        const mob = try self.inSlot(index);
        if (mob.entity.removed) {
            if (mob.entity.placed) self.places.remove(mob.entity.id);
            mob.entity.placed = false;
            return;
        }
        if (mob.entity.placed and mob.entity.placed_world == mob.motion.world and std.meta.eql(mob.entity.placed_position, mob.motion.position)) return;
        // Into a column that does not tick, it leaves the tick list; back into one, it joins last.
        if (mob.entity.placed) try self.places.move(index, mob.motion.world, mob.motion.position) else try self.places.insert(mob.entity.id, mob.motion.world, mob.motion.position, self.shapeOf(mob));
        _ = !mob.entity.placed or mob.entity.placed_world != mob.motion.world or !std.meta.eql(entities.space.columnOf(mob.entity.placed_world, mob.entity.placed_position), entities.space.columnOf(mob.motion.world, mob.motion.position));
        mob.entity.placed = true;
        mob.entity.placed_world = mob.motion.world;
        mob.entity.placed_position = mob.motion.position;
    }

    /// Forgets a removed mob. Its viewers have been told, so the slot is free.
    pub fn release(self: *Mobs, index: u32) !void {
        const mob = try self.inSlot(index);
        assert(mob.entity.removed);
        if (self.boats) |boats| boats.forgetMob(index);
        if (mob.entity.placed) self.places.remove(mob.entity.id);
        mob.entity.placed = false;
        self.releasePath(mob);
        const entity = mob.entity.id;
        if (!mob.entity.unloaded) try self.forgetRecord(index, entity);
        self.active.remove(index);
        self.extras.free(self.rows.ref(index).field("extras"));
        self.rows.remove(index);
        self.deps.entities.leave(index);
    }

    /// The slot of a mob in the world, if it is.
    pub fn slotOf(self: *const Mobs, entity: u64) ?u32 {
        const directory = &self.deps.entities.directory;
        const slot = directory.slotOf(entity) orelse return null;
        return if (self.isMob(slot)) slot else null;
    }

    /// Where the components of the mob in a slot lie, good until the tick's end.
    pub fn inSlot(self: *Mobs, index: u32) !Mob {
        const row = self.rows.ref(index);
        var mob: Mob = undefined;
        inline for (Mob.groups) |name| @field(mob, name) = row.field(name);
        mob.extras = .{ .table = .{ .link = row.field("extras"), .store = &self.extras } };
        return mob;
    }

    fn rowOf(state: MobState) Row {
        var row: Row = undefined;
        row.tracking = .{};
        row.extras = mob_extras.none;
        inline for (Mob.groups) |name| @field(row, name) = @field(state, name);
        return row;
    }

    /// Every mob's slot into `ordered`: those in the tick order in its order, then the rest by id.
    /// How many there are.
    pub fn collectOrder(self: *Mobs) !usize {
        const core = &self.rows.core;
        var count: usize = 0;
        for ([_]*const entities.Array(u32){ &core.ticking, &core.dormant }, 0..) |list, part| {
            const first = count;
            for (0..list.len) |at| {
                const block = core.page(list.at(at).*);
                for (0..entities.kind_table.Core.counter(block).*) |r| {
                    const row: u32 = @intCast(r);
                    if (!core.bit(block, core.layout.alive, row)) continue;
                    try self.ordered.ensure(count + 1);
                    self.ordered.at(count).* = core.slots(block)[row];
                    count += 1;
                }
            }
            if (part == 0) continue;
            const ById = struct {
                mobs: *Mobs,
                fn id(sort: @This(), at: usize) u64 {
                    return sort.mobs.deps.entities.directory.entry(sort.mobs.ordered.at(at).*).id;
                }
                pub fn lessThan(sort: @This(), a: usize, b: usize) bool {
                    return sort.id(a) < sort.id(b);
                }
                pub fn swap(sort: @This(), a: usize, b: usize) void {
                    std.mem.swap(u32, sort.mobs.ordered.at(a), sort.mobs.ordered.at(b));
                }
            };
            std.sort.pdqContext(first, count, ById{ .mobs = self });
        }
        return count;
    }

    /// How many slots there may be: one for every entity the directory may hold.
    pub fn slotCount(self: *const Mobs) usize {
        return self.deps.entities.directory.capacity();
    }

    /// A placed mob's box as lookups meet it, read from its place without its state.
    pub fn placedBox(self: *const Mobs, index: u32) ?body.Box {
        const placed = self.places.space.atSlot(index) orelse return null;
        const box = placed.entry.box();
        return .{ .min = box.min, .max = box.max };
    }

    /// A copy of the mob in a slot, as it stands, idle hot fields aside.
    pub fn copyAt(self: *Mobs, index: u32) !MobState {
        const row = self.rows.ref(index);
        var state: MobState = undefined;
        inline for (Mob.groups) |name| @field(state, name) = row.field(name).*;
        state.rare = self.extras.read(row.field("extras").*);
        return state;
    }

    /// A mob for systems outside the tick, which may change it, so it stops idling first.
    pub fn get(self: *Mobs, entity: u64) !?Mob {
        const index = self.slotOf(entity) orelse return null;
        try self.stopIdling(index);
        // It may be moved, so whether it ticks is asked again.
        self.trackingOf(index).dormant_revision = std.math.maxInt(u64);
        return try self.inSlot(index);
    }

    /// Another mob a mob keeps track of, as a partner or a parent, if it is still in the world.
    /// Read as it stands, idle or not, as goals read their targets.
    pub fn byId(self: *Mobs, entity: u64) !?Mob {
        const index = self.slotOf(entity) orelse return null;
        const mob = try self.inSlot(index);
        if (mob.entity.removed) return null;
        return mob;
    }

    /// The mob stops idling, if it does: whatever changes it next, its full tick follows.
    fn stopIdling(self: *Mobs, index: u32) !void {
        self.trackingOf(index).idling = false;
    }

    /// What the mobs keep beside a mob's state, good until the tick's end.
    pub fn trackingOf(self: *Mobs, index: u32) *Tracking {
        return self.rows.ref(index).field("tracking");
    }

    /// Whether the mob idles, so nothing about it changes but its idle group.
    pub fn idles(self: *Mobs, index: u32) bool {
        return self.trackingOf(index).idling;
    }

    /// Wakes a resting mob, which then ticks in full.
    pub fn rouse(self: *Mobs, index: u32) !void {
        self.rouseHeld(index, try self.inSlot(index));
    }

    /// Wakes a resting mob in hand.
    fn rouseHeld(self: *Mobs, index: u32, mob: Mob) void {
        self.trackingOf(index).idling = false;
        mob.motion.resting = false;
    }

    pub const EventsFull = struct { context: *anyopaque, call: *const fn (*anyopaque) void };

    /// Notes what befell a mob for its viewers. Full, everything held goes now, as vanilla
    /// sends each when it happens. Copies Debug checks run on tell nobody.
    fn happen(self: *Mobs, mob: Mob, what: @FieldType(mob_state.Event, "what")) void {
        if (!self.inPool(mob)) return;
        if (self.event_count == self.events.len) {
            if (self.events_full) |hook| hook.call(hook.context);
            self.event_count = 0;
        }
        self.events[self.event_count] = .{ .slot = self.slotOf(mob.entity.id).?, .id = mob.entity.id, .what = what };
        self.event_count += 1;
    }

    /// The events held since last taken, which the taker sends.
    pub fn takeEvents(self: *Mobs) []const mob_state.Event {
        defer self.event_count = 0;
        return self.events[0..self.event_count];
    }

    /// Before entities tick: mobs learn their places in the order, edits held are answered,
    /// and what idle mobs look for is noted.
    pub fn prepareTick(self: *Mobs) !void {
        if (self.failure) |err| return err;
        if (!self.loaded_all and !self.deps.entities.columns_followed) try self.loadAll();
        self.loaded_all = true;
        self.tickViews(true);
        try self.noteHeldFood();
        try self.answerEdits();
        try self.wakeTouched();
        const audience = self.noteAudience();
        const cow = self.traits(.cow);
        const species: herd_state.Species = .{ .tempt_range = cow.attribute(.tempt_range), .eye_height = cow.eye_height, .ambient_interval = cow.ambient_interval };
        self.context = .{ .audience = audience, .species = species, .volume = cow.sound_volume };
    }

    /// A mob's pushEntities finds the players its box meets, and each pushes it, which one
    /// resting or idling skips: so each a player touches wakes first. Waking one more than
    /// needed, as by a player on a ladder, which is not pushable, changes nothing.
    fn wakeTouched(self: *Mobs) !void {
        if (self.active.count == 0) return;
        const players = self.deps.players;
        for (players.activeSlots()) |index| {
            const player = &players.records[index];
            if (!player.inWorld()) continue;
            const state = self.deps.player_states.of(player);
            if (state.gamemode == .spectator or state.health <= 0) continue;
            var touch: Wake = .{ .mobs = self, .box = playerBox(player) };
            try self.places.space.each(player.world, .{ .min = touch.box.min, .max = touch.box.max }, self.kinds, &touch, Wake.visit);
        }
    }

    const Wake = struct {
        mobs: *Mobs,
        box: body.Box,

        fn visit(touch: *Wake, entry: entities.space.Entry) anyerror!bool {
            const mob = try touch.mobs.inSlot(entry.slot);
            if (mob.entity.removed or !living.box(touch.mobs, mob).intersects(touch.box)) return false;
            touch.mobs.rouseHeld(entry.slot, mob);
            return false;
        }
    };

    /// Mobs next in ServerLevel's entity tick list: runs of idle ones side by side in the mobs'
    /// table, one per lane, advance at once.
    pub fn tickRun(self: *Mobs, entries: []const entities.order.Entry) !void {
        const context = &self.context;
        var at: usize = 0;
        while (at < entries.len) {
            if (at + herd_state.lane_count <= entries.len) if (self.idleRun(entries[at..][0..herd_state.lane_count], &context.ticking)) |first| {
                try self.tickBlock(first, context);
                at += herd_state.lane_count;
                continue;
            };
            defer at += 1;
            // One gone from the world since the pass began is passed over.
            const index = self.slotOf(entries[at].id) orelse continue;
            // ServerLevel ticks a passenger after what it rides, not on its own turn.
            if (self.rides(index)) continue;
            try self.tickPlace(index, context);
        }
    }

    /// The id a mob was given in memory, the wire's: what vanilla's getId gives.
    pub fn givenId(self: *const Mobs, mob: Mob) u32 {
        return @intCast(self.deps.entities.networkOf(mob.entity.id).?);
    }

    /// The id a mob in a slot was given, as `givenId`.
    fn givenOfSlot(slot: u32) i32 {
        return entities.Entities.networkOfSlot(slot);
    }

    /// Whether an entity's slot holds a mob of the mobs' table.
    fn isMob(self: *const Mobs, slot: u32) bool {
        const entry = self.deps.entities.directory.entry(slot);
        return entry.block != entities.directory.none and self.places.order.cores[entry.kind] == &self.rows.core;
    }

    pub fn finishTick(self: *Mobs) !void {
        self.tickViews(false);
    }

    /// A mob's box as lookups meet it: its kind's size, a baby's when young.
    fn shapeOf(self: *const Mobs, mob: Mob) entities.Shape {
        return .{ .kind = self.traits(mob.entity.species).entity_type, .half_width = living.width(self, mob) / 2.0, .height = living.height(self, mob) };
    }

    const TickContext = struct {
        audience: herd_state.Audience,
        species: herd_state.Species,
        volume: f32,
        ticking: TickingMemo = .{},
    };

    /// Whether an idle mob's column ticks, which holds until the domains change.
    fn idleTicks(self: *Mobs, tracking: *Tracking, motion: *const mob_state.Motion, ticking: *TickingMemo) bool {
        return self.knownTicks(tracking, motion.world, chunkOf(motion.position), ticking);
    }

    /// Where the run of mobs next in the tick list lies in the mobs' table, if all are idle and
    /// ticking and side by side in one block.
    fn idleRun(self: *Mobs, entries: []const entities.order.Entry, ticking: *TickingMemo) ?Table.Ref {
        const directory = &self.deps.entities.directory;
        const first = directory.entry(entries[0].slot);
        if (first.block == entities.directory.none or first.dormant or @as(usize, first.row) + entries.len > Table.rows) return null;
        const block = self.rows.core.page(first.block);
        const trackings = Table.columnOf(block, "tracking");
        const motions = Table.columnOf(block, "motion");
        for (entries, 0..) |entry, offset| {
            const held = directory.entry(entry.slot);
            const row = first.row + offset;
            if (held.block != first.block or held.row != row or held.kind != first.kind or !self.isMob(entry.slot)) return null;
            if (!trackings[row].idling or !self.idleTicks(&trackings[row], &motions[row], ticking)) return null;
        }
        return .{ .block = block, .row = first.row };
    }

    fn tickBlock(self: *Mobs, first: Table.Ref, context: *TickContext) !void {
        const lanes = herd_state.lane_count;
        const slots = self.rows.core.slots(first.block)[first.row..][0..lanes];
        var before: [lanes]MobState = undefined;
        if (verify_idle) for (&before, slots) |*lane, slot| {
            lane.* = try self.copyAt(slot);
        };
        const trackings = Table.columnOf(first.block, "tracking")[first.row..][0..lanes];
        const controls = Table.columnOf(first.block, "control")[first.row..][0..lanes];
        var run: herd_state.Run = .{
            .idle = Table.columnOf(first.block, "idle")[first.row..][0..lanes],
            .motion = Table.columnOf(first.block, "motion")[first.row..][0..lanes],
            .persistent = undefined,
            .given = undefined,
            .gaze_yaw = undefined,
        };
        inline for (0..lanes) |lane| {
            run.persistent[lane] = controls[lane].persistence_required;
            run.given[lane] = givenOfSlot(slots[lane]);
            run.gaze_yaw[lane] = trackings[lane].gaze_yaw;
        }
        const block = herd_state.advanceBlock(run, context.audience, context.species);
        self.idle_blocks += 1;
        if (!block.any_rare) {
            herd_state.commitBlock(run, &block);
            self.idle_ticks += lanes;
            if (verify_idle) for (before, slots) |lane, slot| try self.checkIdle(slot, lane);
            return;
        }
        // In order: a rare lane takes its own tick, which may wake the lanes after it.
        for (0..lanes) |offset| {
            const slot = slots[offset];
            if (block.rare[offset] or !trackings[offset].idling) {
                if (block.rare[offset]) self.rare_lanes += 1;
                try self.tickPlace(slot, context);
                continue;
            }
            herd_state.commitLane(&run.idle[offset], &block, offset);
            self.idle_ticks += 1;
            if (verify_idle) try self.checkIdle(slot, before[offset]);
        }
    }

    fn tickPlace(self: *Mobs, index: u32, context: *TickContext) !void {
        const row = self.rows.ref(index);
        const tracking = row.field("tracking");
        // An idle mob is read from its idle group alone, without touching the rest.
        if (tracking.idling) {
            const motion = row.field("motion");
            if (!self.idleTicks(tracking, motion, &context.ticking)) return;
            const before = if (verify_idle) try self.copyAt(index) else {};
            const still: herd_state.Still = .{ .world = motion.world, .position = motion.position, .persistent = row.field("control").persistence_required, .given = givenOfSlot(index) };
            switch (herd_state.advance(row.field("idle"), still, &tracking.gaze_yaw, context.audience, context.species)) {
                .idled => |sound| {
                    self.idle_ticks += 1;
                    // Mob.playAmbientSound, once the tick is sure to stand.
                    if (sound) |pitch| {
                        const at = motion.position;
                        self.effects.sound(motion.world, .{ .x = at[0], .y = at[1], .z = at[2] }, Sound.cow_ambient.name(), .neutral, context.volume, pitch, @bitCast(self.sound_seeds.next()), null);
                    }
                    if (verify_idle) try self.checkIdle(index, before);
                    return;
                },
                // Something starts, so the mob takes its full tick from the start.
                .started => tracking.idling = false,
            }
        }
        if (tracking.dormant_revision == self.domain_revision) return;
        const mob = try self.inSlot(index);
        if (mob.entity.removed) return;
        if (!self.columnTicks(index, mob, &context.ticking)) {
            tracking.dormant_revision = self.domain_revision;
            return;
        }
        // An awake mob reads the blocks around it many times over, so they are read once. A resting
        // one reads almost none.
        if (!mob.motion.resting) {
            const around = self.level(mob.motion.world);
            try self.window.fill(&around, mob.blockPosition());
            self.window_view = &self.window;
        }
        {
            defer self.window_view = null;
            try mob_tick.tick(self, mob);
        }
        // Done, its path's nodes are read no more.
        if (navigation.done(mob)) self.releasePath(mob);
        try self.locate(index);
        // Blocks the mob changed, as trampled farmland, before the next mob moves.
        try self.answerEdits();
        if (!tracking.idling and !self.rides(index) and herd_state.idle(self, mob)) {
            tracking.idling = true;
            tracking.gaze_yaw = herd_state.gazeYaw(mob);
            tracking.fresh = true;
        }
    }

    /// Whether a mob rides something, which ticks it after itself.
    pub fn rides(self: *const Mobs, slot: u32) bool {
        return self.deps.entities.vehicleOf(slot) != null;
    }

    /// Mob.rideTick for a mob a boat carries: Entity.rideTick's still start and full tick, then
    /// LivingEntity.rideTick's fall forgotten. Its vehicle places it after.
    pub fn rideTick(self: *Mobs, slot: u32) !void {
        const mob = try self.inSlot(slot);
        if (mob.entity.removed) return;
        mob.motion.velocity = .{ 0, 0, 0 };
        mob.motion.resting = false;
        self.trackingOf(slot).idling = false;
        try self.tickPlace(slot, &self.context);
        (try self.inSlot(slot)).motion.fall_distance = 0;
    }

    /// Entity.positionRider for a mob, with AbstractBoat.positionRider's turns: at the seat, its
    /// body the vehicle's way, its look within 105 degrees of it, and a quarter turn out for an
    /// animal in a full boat, by its id. The boat's own turn it would add is none on a server,
    /// as only a client steering turns one.
    pub fn seatRider(self: *Mobs, slot: u32, seat: [3]f64, vehicle_yaw: f32, full: bool) !void {
        const mob = try self.inSlot(slot);
        if (mob.entity.removed) return;
        mob.motion.position = seat;
        // AbstractBoat.clampRotation.
        mob.idle.body_yaw = vehicle_yaw;
        const off = mth.wrapDegrees(mob.motion.yaw - vehicle_yaw);
        const kept = mth.clamp(off, -105.0, 105.0);
        mob.motion.old_yaw += kept - off;
        mob.motion.yaw += kept - off;
        mob.idle.head_yaw = mob.motion.yaw;
        if (full) {
            const turn: f32 = if (@rem(givenOfSlot(slot), 2) == 0) 90 else 270;
            mob.idle.body_yaw += turn;
            mob.idle.head_yaw += turn;
        }
        try self.locate(slot);
    }

    /// Where a mob is set down off a vehicle, and placed there: Entity.dismountTo.
    pub fn dismountTo(self: *Mobs, slot: u32, at: [3]f64) !void {
        const mob = try self.inSlot(slot);
        mob.motion.position = at;
        mob.motion.resting = false;
        try self.locate(slot);
    }

    /// The players idle mobs look for, as mobs start ticking and players stand still.
    fn noteAudience(self: *Mobs) herd_state.Audience {
        self.present_count = 0;
        self.holder_count = 0;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (player.stage != .ready or self.deps.player_states.of(player).gamemode == .spectator) continue;
            const entry: herd_state.Audience.Player = .{ .world = player.world, .position = .{ player.position.x, player.position.y, player.position.z } };
            self.present[self.present_count] = entry;
            self.present_count += 1;
            if (!self.holding_food[slot]) continue;
            self.holders[self.holder_count] = entry;
            self.holder_count += 1;
        }
        return .{ .present = self.present[0..self.present_count], .holding_food = self.holders[0..self.holder_count] };
    }

    /// Debug builds check every idle tick against the full tick it stands for.
    const verify_idle = @import("builtin").mode == .debug;

    fn checkIdle(self: *Mobs, index: u32, before: MobState) !void {
        var expected = before;
        // The full tick on the copy plays nothing, as the idle tick already did.
        self.muted = true;
        defer self.muted = false;
        try mob_tick.tick(self, Mob.of(&expected));
        const actual = try self.copyAt(index);
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("idle tick diverged for mob {d}\n", .{actual.entity.id});
            unreachable;
        }
    }

    /// Whether a mob's chunk ticks, remembering the last chunk asked about.
    const TickingMemo = struct {
        world: u32 = 0,
        chunk: ?[2]i32 = null,
        result: bool = false,

        fn ticks(self: *TickingMemo, mobs: *Mobs, world: u32, chunk: [2]i32) bool {
            if (self.chunk) |known| if (known[0] == chunk[0] and known[1] == chunk[1] and self.world == world) return self.result;
            self.world = world;
            self.chunk = chunk;
            self.result = mobs.deps.domains.ticks(.{ .world = world, .x = chunk[0], .z = chunk[1] });
            return self.result;
        }
    };

    /// Whether a mob's column ticks, asking the domains only when they or the column changed.
    fn columnTicks(self: *Mobs, index: u32, mob: Mob, ticking: *TickingMemo) bool {
        return self.knownTicks(self.trackingOf(index), mob.motion.world, chunkOf(mob.motion.position), ticking);
    }

    fn knownTicks(self: *Mobs, tracking: *Tracking, world: u32, chunk: [2]i32, ticking: *TickingMemo) bool {
        const known = &tracking.column;
        if (known.revision == self.domain_revision and known.world == world and std.meta.eql(known.chunk, chunk)) return known.ticks;
        known.* = .{ .revision = self.domain_revision, .world = world, .chunk = chunk, .ticks = ticking.ticks(self, world, chunk) };
        return known.ticks;
    }

    fn domainsChanged(self: *Mobs, _: []const @import("domains").domains.Column, _: []const @import("domains").domains.Column) void {
        self.domain_revision += 1;
    }

    /// ServerLevel.sendBlockUpdated, first half. Edits come here after they apply, a batch at a
    /// time, with what they replaced. From the first that changes a collision shape on, every edit
    /// is kept until the next answer, so each path that recomputes can see the world as it stood.
    fn blocksChanged(self: *Mobs, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        if (self.active.count == 0) return;
        // The window around the mob ticking shows edits as they happen.
        if (self.window_view != null) for (edits) |edit| {
            const at: i32 = edit.index;
            self.window.edit(section.world, .{ section.x * 16 + (at & 15), section.y * 16 + (at >> 8), section.z * 16 + ((at >> 4) & 15) }, edit.state);
        };
        // Resting mobs near any edit wake, a section's batch at a time.
        var low: [3]i32 = .{ 15, 15, 15 };
        var high: [3]i32 = .{ 0, 0, 0 };
        for (edits) |edit| {
            const index: i32 = edit.index;
            const cell: [3]i32 = .{ index & 15, index >> 8, (index >> 4) & 15 };
            for (0..3) |axis| {
                low[axis] = @min(low[axis], cell[axis]);
                high[axis] = @max(high[axis], cell[axis]);
            }
        }
        const origin: [3]i32 = .{ section.x * 16, section.y * 16, section.z * 16 };
        self.wake(section.world, .{ @floatFromInt(origin[0] + low[0]), @floatFromInt(origin[1] + low[1]), @floatFromInt(origin[2] + low[2]) }, .{ @floatFromInt(origin[0] + high[0] + 1), @floatFromInt(origin[1] + high[1] + 1), @floatFromInt(origin[2] + high[2] + 1) });
        for (edits, previous, 0..) |edit, old, at| {
            const collision = self.blocks.get(old).collision != self.blocks.get(edit.state).collision;
            if (self.edit_count == self.edits.len) {
                // Full: what is held is answered now, against the world before this edit.
                self.later = .{ .section = section, .edits = edits[at..], .previous = previous[at..] };
                defer self.later = null;
                self.edits_answered_early += 1;
                self.answerEdits() catch |err| {
                    self.failure = err;
                    return;
                };
            }
            if (!collision and self.edit_count == 0) continue;
            const index: i32 = edit.index;
            self.edits[self.edit_count] = .{
                .world = section.world,
                .position = .{ section.x * 16 + (index & 15), section.y * 16 + (index >> 8), section.z * 16 + ((index >> 4) & 15) },
                .previous = old,
                .collision = collision,
                .game_time = self.gameTime(),
            };
            self.edit_count += 1;
        }
    }

    /// ServerLevel.sendBlockUpdated, second half, for the edits held since the last answer, in
    /// their order. A mob following a path near an edit that changed a collision finds the way
    /// again, at the edit's game time and against the world as of the edit. Mobs have not moved
    /// since, as edits are answered before mobs tick and after each one that ticks.
    ///
    /// A path is found against blocks alone, so each mob may answer every edit in turn before
    /// the next mob.
    fn answerEdits(self: *Mobs) !void {
        if (self.edit_count == 0) return;
        defer self.edit_count = 0;
        defer self.overlay_view = null;
        var laid_after: ?usize = null;
        for (0..self.active.count) |active_at| {
            const index = self.active.at(active_at);
            try self.answerFor(@intCast(index), &laid_after);
        }
    }

    /// One mob following a path answers the held edits that changed collisions, in order.
    fn answerFor(self: *Mobs, index: u32, laid_after: *?usize) !void {
        const mob = try self.inSlot(index);
        if (mob.entity.removed or navigation.done(mob) or mob.navigation.has_delayed_recomputation) return;
        if (!self.loaded(mob.motion.world, mob.blockPosition())) return;
        for (self.edits[0..self.edit_count], 0..) |edit, at| {
            if (!edit.collision) continue;
            if (mob.motion.world != edit.world or !navigation.shouldRecomputePath(self, mob, edit.position)) continue;
            if (laid_after.* != at) {
                self.layOver(at);
                laid_after.* = at;
            }
            self.edit_recomputes += 1;
            try navigation.recomputePath(self, mob, edit.game_time);
        }
    }

    fn layOver(self: *Mobs, at: usize) void {
        self.overlay.layAfter(self.edits[0..self.edit_count], at);
        // Answered early, the edits after the held ones show already: they are undone too.
        if (self.later) |later| {
            layLaterSection(&self.overlay, later.section, later.edits, later.previous);
            const batch = self.deps.chunks.notifiedLater();
            var offset: usize = 0;
            for (batch.sections) |section| {
                layLaterSection(&self.overlay, section.section, section.edits, batch.previous[offset..][0..section.edits.len]);
                offset += section.edits.len;
            }
            assert(offset == batch.previous.len);
        }
        self.overlay_view = if (self.overlay.states.count() == 0) null else &self.overlay;
    }

    const Later = struct { section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16 };

    fn layLaterSection(overlay: *body.Overlay, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        for (edits, previous) |edit, old| {
            const index: i32 = edit.index;
            overlay.layLater(section.world, .{ section.x * 16 + (index & 15), section.y * 16 + (index >> 8), section.z * 16 + ((index >> 4) & 15) }, old);
        }
    }

    /// The game time, Level.getGameTime, which navigation times stalls and recomputations by.
    pub fn gameTime(self: *const Mobs) i64 {
        return self.deps.time.game_time;
    }

    /// Every mob's place, motion and path, for telling two runs apart; idle mobs as the herd has them.
    pub fn digest(self: *Mobs) !u64 {
        var sum: u64 = 0;
        for (0..self.active.count) |active_at| {
            const index = self.active.at(active_at);
            var current = try self.copyAt(@intCast(index));
            if (current.entity.removed) continue;
            var hasher = std.hash.Wyhash.init(current.entity.id);
            hasher.update(std.mem.asBytes(&current.motion.position));
            hasher.update(std.mem.asBytes(&current.motion.velocity));
            const path = current.navigation.path;
            hasher.update(std.mem.asBytes(&[_]u64{ @intFromBool(path.active), path.count, path.next }));
            if (path.active) hasher.update(std.mem.asBytes(&path.fingerprint));
            sum +%= hasher.final();
        }
        return sum;
    }

    /// One node of the path a mob follows.
    pub fn pathNode(self: *Mobs, mob: Mob, index: usize) pathfinding.PathNode {
        const path = mob.navigation.path;
        assert(path.nodes != mob_state.no_nodes and index < path.count);
        var node: pathfinding.PathNode = undefined;
        self.path_nodes.read(path.nodes, index * @sizeOf(pathfinding.PathNode), std.mem.asBytes(&node));
        return node;
    }

    /// The nodes of the path a mob follows, read whole into the mobs' working copy, good until
    /// the next read; `writePathNodes` keeps changes to them.
    pub fn pathNodes(self: *Mobs, mob: Mob) []pathfinding.PathNode {
        const path = mob.navigation.path;
        if (path.nodes == mob_state.no_nodes) {
            assert(path.count == 0 or navigation.done(mob));
            return &.{};
        }
        const nodes = self.path_work[0..path.count];
        self.path_nodes.read(path.nodes, 0, std.mem.sliceAsBytes(nodes));
        return nodes;
    }

    pub fn writePathNodes(self: *Mobs, mob: Mob, nodes: []const pathfinding.PathNode) void {
        self.path_nodes.write(mob.navigation.path.nodes, 0, std.mem.sliceAsBytes(nodes));
    }

    /// The path last found becomes the mob's, its nodes in a blob of their own.
    pub fn takeFoundPath(self: *Mobs, mob: Mob) !void {
        assert(self.inPool(mob));
        self.releasePath(mob);
        const fresh = self.scratch_path[0..self.scratch.count];
        var path: mob_state.Path = .{ .active = true, .count = self.scratch.count, .next = 0, .target = self.scratch.target, .reached = self.scratch.reached, .fingerprint = navigation.fingerprint(fresh) };
        if (fresh.len > 0) {
            path.nodes = try self.path_nodes.create(std.mem.sliceAsBytes(fresh));
            const last = fresh[fresh.len - 1];
            path.end = .{ last.x, last.y, last.z };
        }
        mob.navigation.path = path;
    }

    /// Gives back the nodes of a mob's path, if it holds any.
    pub fn releasePath(self: *Mobs, mob: Mob) void {
        const path = &mob.navigation.path;
        if (path.nodes == mob_state.no_nodes) return;
        self.path_nodes.free(path.nodes);
        path.nodes = mob_state.no_nodes;
    }

    /// Whether the chunk holding a position is loaded, as ChunkSource.getChunkNow asks: a
    /// column mobs may read.
    pub fn loaded(self: *const Mobs, world: u32, position: [3]i32) bool {
        return self.deps.domains.readable(.{ .world = world, .x = @divFloor(position[0], 16), .z = @divFloor(position[2], 16) });
    }

    /// Tags come with the definitions, which a datapack may change.
    fn readTags(self: *Mobs) !void {
        const tags = &self.deps.items.deps.definitions.tags;
        self.food_tag = tags.find("minecraft:cow_food");
    }

    pub fn damageFlags(self: *const Mobs, damage_type: mob_state.DamageType) damage_types.Flags {
        return self.deps.damage_types.flagsOf(damage_type);
    }

    /// The damage type's id in the registry players were sent.
    pub fn damageTypeId(self: *const Mobs, damage_type: mob_state.DamageType) i32 {
        return self.deps.damage_types.idOf(damage_type);
    }

    /// AbstractCow.isFood: the cow_food item tag.
    fn noteHeldFood(self: *Mobs) !void {
        for (self.deps.players.activeSlots()) |slot| self.holding_food[slot] = try self.holdsFoodNow(@intCast(slot));
    }

    /// Whether a player holds food the mob is tempted by in either hand.
    fn holdsFoodNow(self: *Mobs, slot: u32) !bool {
        const player = &self.deps.players.records[slot];
        const state = self.deps.player_states.of(player);
        const slots = [_]inventories.Slot{
            .{ .owner = player.uuid, .index = 36 + @as(u16, state.selected_slot) },
            .{ .owner = player.uuid, .index = 45 },
        };
        for (slots) |held| {
            const stack = (try self.deps.inventories.get(held)).stack orelse continue;
            if (try self.isFood(stack)) return true;
        }
        return false;
    }

    /// Whether the player held cow food when mobs started ticking.
    pub fn holdsFood(self: *const Mobs, slot: u32) bool {
        assert(self.ticking);
        return self.holding_food[slot];
    }

    pub fn isFood(self: *Mobs, stack: inventories.Stack) !bool {
        const tag = self.food_tag orelse return false;
        const pinned = try self.deps.items.acquire(stack);
        defer pinned.release();
        return self.deps.items.deps.definitions.tags.contains(tag, pinned.view.kind);
    }

    /// PanicGoal.shouldPanic: damage of a type in panic_causes, in the last two seconds, as
    /// LivingEntity.getLastDamageSource forgets older damage.
    pub fn shouldPanic(self: *Mobs, mob: Mob) bool {
        const memory = mob.part(.hurt) orelse return false;
        if (self.gameTime() - memory.stamp > 40) {
            mob.drop(.hurt);
            return false;
        }
        return self.damageFlags(memory.damage.type).panic;
    }

    /// Animal.getWalkTargetValue: grass underfoot is best, else the light, through
    /// LevelReader.getPathfindingCostFromLightLevels.
    pub fn walkTargetValue(self: *Mobs, mob: Mob, position: [3]i32) !f32 {
        const reader = self.level(mob.motion.world);
        if (reader.blocks.get(try reader.state(position[0], position[1] - 1, position[2])).kind == .grass_block) return 10.0;
        const brightness: f32 = @floatFromInt(try self.rawBrightness(mob.motion.world, position));
        const fraction = brightness / 15.0;
        const curve = fraction / (4.0 - 3.0 * fraction);
        // Dimensions mobs live in here have no ambient light.
        return mth.lerp(0.0, curve, 1.0) - 0.5;
    }

    /// LevelLightEngine.getRawBrightness with the sky darkened by time and weather. Light not
    /// in memory reads as dark, which a loaded chunk in vanilla never is.
    fn rawBrightness(self: *Mobs, world: u32, position: [3]i32) !u8 {
        var sample: [1]?LightSample = undefined;
        try self.deps.lighting.sampleMany(world, &.{.{ .x = position[0], .y = position[1], .z = position[2] }}, &sample);
        const light = sample[0] orelse return 0;
        return @max(light.block, light.sky -| self.skyDarken());
    }

    /// Level.calculateAmbientDarkness, as growth computes it.
    fn skyDarken(self: *const Mobs) u4 {
        const day: f64 = @floatFromInt(@mod(self.deps.time.day_time, 24000));
        const turn = day / 24000 - 0.25 - @floor(day / 24000 - 0.25);
        const angle = (turn * 2 + (0.5 - @cos(turn * std.math.pi) / 2)) / 3;
        var light = 1 - std.math.clamp(1 - (@cos(angle * 2 * std.math.pi) * 2 + 0.5), 0, 1);
        light *= 1 - @as(f64, self.deps.weather.rain_level) * 5 / 16;
        light *= 1 - @as(f64, self.deps.weather.thunder_level) * 5 / 16;
        return @intFromFloat((1 - light) * 11);
    }

    /// Animal.spawnChildFromBreeding with Cow.getBreedOffspring.
    pub fn breed(self: *Mobs, mob: Mob, partner: Mob) !void {
        const variant = if (mob.idle.random.nextBoolean()) mob.cow.variant else partner.cow.variant;
        const child = try self.spawnChild(mob, variant);
        _ = child;
        // Animal.finalizeSpawnChildFromBreeding.
        self.setAge(mob, 6000);
        self.setAge(partner, 6000);
        mob.endLove();
        partner.endLove();
        self.entityEvent(mob, 18);
        // One orb of one to seven, from the mob's own random, when mobs drop loot.
        const value = mob.idle.random.nextIntBounded(7) + 1;
        try self.deps.experience.spawnOrb(mob.motion.world, mob.motion.position, value);
    }

    fn spawnChild(self: *Mobs, parent: Mob, variant: u8) !u64 {
        // EntityType.create for breeding, then setBaby and snapTo the parent with no rotation.
        return self.spawn(.{ .species = parent.entity.species, .world = parent.motion.world, .position = parent.motion.position, .yaw = 0, .baby = true, .variant = variant, .finalize = false });
    }

    // What moving and living cause.

    pub fn playSound(self: *Mobs, mob: Mob, sound: Sound, volume: f32, pitch: f32) void {
        if (self.muted) return;
        const at: minecraft.Position = .{ .x = mob.motion.position[0], .y = mob.motion.position[1], .z = mob.motion.position[2] };
        self.effects.sound(mob.motion.world, at, sound.name(), .neutral, volume, pitch, @bitCast(self.sound_seeds.next()), null);
    }

    pub fn blockSound(self: *Mobs, world: u32, at: [3]f64, sound: Sound, volume: f32, pitch: f32) void {
        self.effects.sound(world, .{ .x = at[0], .y = at[1], .z = at[2] }, sound.name(), .blocks, volume, pitch, @bitCast(self.sound_seeds.next()), null);
    }

    /// Mob.playStepSound as each species overrides it.
    pub fn stepSound(self: *Mobs, mob: Mob, _: u16) void {
        switch (mob.entity.species) {
            .cow => self.playSound(mob, .cow_step, 0.15, 1.0),
        }
    }

    /// The block's fall sound at half volume and three quarters pitch. Block sound types are not
    /// in the snapshot yet, so this plays the generic fall sound.
    pub fn blockFallSound(self: *Mobs, mob: Mob, _: u16) void {
        self.playSound(mob, .generic_small_fall, 0.5, 0.75);
    }

    /// ServerLevel.sendParticles of block particles. Particle packets are not written yet.
    pub fn blockParticles(_: *Mobs, _: u32, _: [3]f64, _: u16, _: i32, _: f32) void {}

    pub fn hurt(self: *Mobs, mob: Mob, dealt: mob_state.Damage, amount: f32) !bool {
        return damage.hurt(self, mob, dealt, amount);
    }

    /// ServerPlayer.crit and magicCrit's ClientboundAnimatePacket, for the replication to send.
    pub fn animate(self: *Mobs, mob: Mob, animation: Animation) void {
        self.happen(mob, .{ .animation = @backingInt(animation) });
    }

    pub const Animation = enum(u8) { critical_hit = 4, enchanted_hit = 5 };

    /// Entity.igniteForSeconds through LivingEntity.igniteForTicks: whole ticks, lengthened by
    /// the burning_time attribute, and never shortening a fire already burning.
    pub fn ignite(self: *Mobs, mob: Mob, seconds: f32) void {
        assert(std.math.isFinite(seconds));
        const base: f64 = @floatFromInt(mth.floorFloat(seconds * 20.0));
        const ticks = std.math.lossyCast(i32, @ceil(base * self.traits(mob.entity.species).attribute(.burning_time)));
        if (mob.entity.fire_ticks >= ticks) return;
        mob.entity.fire_ticks = ticks;
        mob.entity.revision += 1;
        self.rouseMob(mob);
    }

    /// ServerLevel.broadcastDamageEvent, for the replication to send.
    pub fn damageEvent(self: *Mobs, mob: Mob, dealt: mob_state.Damage) void {
        self.happen(mob, .{ .damage = dealt });
    }

    /// LivingEntity.knockback. A direction too short to normalize turns random, from Math.random
    /// rather than the mob's random.
    pub fn knockback(self: *Mobs, mob: Mob, strength_in: f64, x_in: f64, z_in: f64) void {
        const strength = strength_in * (1.0 - self.traits(mob.entity.species).attribute(.knockback_resistance));
        if (strength <= 0) return;
        mob.entity.has_impulse = true;
        var x = x_in;
        var z = z_in;
        const random = self.seeds.random();
        while (x * x + z * z < @as(f64, @as(f32, 1.0e-5))) {
            x = (random.float(f64) - random.float(f64)) * 0.01;
            z = (random.float(f64) - random.float(f64)) * 0.01;
        }
        const direction = mth.normalize(.{ x, 0, z });
        const velocity = mob.motion.velocity;
        mob.motion.velocity = .{
            velocity[0] / 2.0 - direction[0] * strength,
            if (mob.motion.on_ground) @min(0.4, velocity[1] / 2.0 + strength) else velocity[1],
            velocity[2] / 2.0 - direction[2] * strength,
        };
    }

    /// LivingEntity.makeSound: at the mob's volume and voice pitch.
    pub fn makeSound(self: *Mobs, mob: Mob, sound: Sound) void {
        const volume = self.traits(mob.entity.species).sound_volume;
        const pitch = self.voicePitch(mob);
        self.playSound(mob, sound, volume, pitch);
    }

    /// Animal.setInLove: ten seconds of hearts.
    pub fn setInLove(self: *Mobs, mob: Mob, cause: ?u128) !void {
        _ = try mob.put(.breeding, .{ .in_love = 600, .love_cause = cause });
        self.entityEvent(mob, 18);
    }

    /// AgeableMob.ageUp: a baby grows by seconds, and the growth fed to it is remembered.
    pub fn ageUp(self: *Mobs, mob: Mob, seconds: i32, forced: bool) !void {
        const before = mob.idle.age;
        var age = before + seconds * 20;
        if (age > 0) age = 0;
        const grown = age - before;
        self.setAge(mob, age);
        if (forced) {
            const ageing = mob.part(.ageing) orelse try mob.put(.ageing, .{});
            ageing.forced_age += grown;
            if (ageing.forced_age_timer == 0) ageing.forced_age_timer = 40;
        }
        if (mob.idle.age == 0) self.setAge(mob, if (mob.part(.ageing)) |ageing| ageing.forced_age else 0);
    }

    /// ExperienceOrb.award at the mob, as LivingEntity.dropExperience does.
    pub fn awardExperience(self: *Mobs, mob: Mob, amount: i32) !void {
        if (!self.deps.experience.canAward(amount)) return;
        try self.deps.experience.award(mob.motion.world, mob.motion.position, amount);
    }

    /// LivingEntity.dropFromLootTable: the species' table, knowing whether the mob burned, who
    /// killed it and with what, dropped where it died as Entity.spawnAtLocation drops items.
    pub fn dropLoot(self: *Mobs, mob: Mob, dealt: mob_state.Damage, by_player: bool) !void {
        const name = switch (mob.entity.species) {
            .cow => "minecraft:entities/cow",
        };
        const table = self.deps.loot.tables.get(name) orelse return;
        self.loot_scratch.reset();
        var weapon: ?Items.Prepared = null;
        defer if (weapon) |pinned| pinned.release();
        if (dealt.attacker) |slot| {
            const player = &self.deps.players.records[slot];
            const held: inventories.Slot = .{ .owner = player.uuid, .index = 36 + @as(u16, self.deps.player_states.of(player).selected_slot) };
            if ((try self.deps.inventories.get(held)).stack) |stack| weapon = try self.deps.items.acquire(stack);
        }
        var buffer: [loot.maximum_drops]loot.Drop = undefined;
        const context: loot.Context = .{
            .items = self.deps.items.deps.definitions,
            .location = .{ .world = mob.motion.world, .x = mob.motion.position[0], .y = mob.motion.position[1], .z = mob.motion.position[2] },
            .on_fire = mob.entity.fire_ticks > 0,
            .killed_by_player = by_player,
            .attacker_weapon = if (weapon) |pinned| pinned.view else null,
            .smelter = .{ .context = self, .smelt = smelt },
            .enchantment_tags = .{ .context = self, .contains = enchantmentInTag },
            .random = self.loot_random.random(),
            .scratch = &self.loot_scratch,
        };
        const drops = table.evaluate(&context, &buffer) catch |err| switch (err) {
            error.OutOfMemory, error.LootCapacity => return,
            else => return err,
        };
        if (drops.len == 0) return;
        var requests: [loot.maximum_drops]ItemEntities.Spawn = undefined;
        var spawned: [loot.maximum_drops]entities.Id = undefined;
        for (drops, requests[0..drops.len]) |drop, *request| {
            const dx = self.level_random.nextDouble() * 0.2 - 0.1;
            const dz = self.level_random.nextDouble() * 0.2 - 0.1;
            request.* = .{
                .world = mob.motion.world,
                .position = mob.motion.position,
                .velocity = .{ dx, 0.2, dz },
                .stack = .{ .item = try item_data.define(self.deps.inventories, drop.kind, drop.components), .count = @intCast(drop.count) },
            };
        }
        try self.deps.dropped.createMany(requests[0..drops.len], spawned[0..drops.len]);
    }

    fn enchantmentInTag(context: *const anyopaque, tag: []const u8, enchantment: []const u8) bool {
        const self: *const Mobs = @ptrCast(@alignCast(context));
        const registry = self.deps.enchantment_registry.client.get("minecraft:enchantment") orelse return false;
        const found = registry.tags.find(tag) orelse return false;
        const member = registry.id(enchantment) orelse return false;
        return registry.tags.contains(found, member);
    }

    /// SmeltItemFunction: a smelting recipe's result, by the server's furnace recipes.
    fn smelt(context: *const anyopaque, kind: u32) ?loot.Smelted {
        const self: *const Mobs = @ptrCast(@alignCast(context));
        const recipes = self.deps.furnaces.table.recipes;
        if (kind >= recipes.len) return null;
        const recipe = recipes[kind] orelse return null;
        if (recipe.callback != null) return null;
        return .{ .kind = recipe.output, .count = recipe.count };
    }

    /// Level.broadcastEntityEvent: a status byte every viewer gets.
    pub fn entityEvent(self: *Mobs, mob: Mob, event: u8) void {
        self.happen(mob, .{ .status = event });
    }

    /// LivingEntity.tickDeath: the body lies twenty ticks, then goes in a puff.
    pub fn tickDeath(self: *Mobs, mob: Mob) void {
        mob.living.death_time += 1;
        if (mob.living.death_time >= 20 and !mob.entity.removed) {
            self.entityEvent(mob, 60);
            mob.entity.removed = true;
        }
    }

    /// LivingEntity.getVoicePitch.
    pub fn voicePitch(_: *Mobs, mob: Mob) f32 {
        const spread = (mob.idle.random.nextFloat() - mob.idle.random.nextFloat()) * 0.2;
        return spread + (if (mob.baby()) @as(f32, 1.5) else 1.0);
    }

    /// Mob.playAmbientSound.
    pub fn ambientSound(self: *Mobs, mob: Mob) void {
        const volume = self.traits(mob.entity.species).sound_volume;
        const pitch = self.voicePitch(mob);
        switch (mob.entity.species) {
            .cow => self.playSound(mob, .cow_ambient, volume, pitch),
        }
    }

    /// AgeableMob.setAge: growing up or becoming a baby changes the size viewers see.
    pub fn setAge(self: *Mobs, mob: Mob, age: i32) void {
        const was_baby = mob.idle.age < 0;
        mob.idle.age = age;
        if (was_baby == (age < 0)) return;
        mob.entity.revision +%= 1;
        // A new size reaches new blocks and mobs, and others find it by its new box at once.
        const grown = living.box(self, mob);
        self.wake(mob.motion.world, grown.min, grown.max);
        if (self.inPool(mob) and mob.entity.placed) self.places.space.reshape(mob.entity.id, self.shapeOf(mob));
    }

    /// Whether a mob is one the plugin holds, and not a copy Debug checks run on.
    fn inPool(self: *const Mobs, mob: Mob) bool {
        const address = @intFromPtr(mob.entity);
        const memory = self.deps.entities.pool.memory;
        return address >= @intFromPtr(memory.ptr) and address < @intFromPtr(memory.ptr + memory.len);
    }

    /// Wakes the resting mobs within reach of a region, which then tick in full. A resting mob
    /// reads blocks up to two outside its box, and touches mobs inside it.
    pub fn wake(self: *Mobs, world: u32, low: [3]f64, high: [3]f64) void {
        const margin = 2.0;
        const reach: body.Box = .{ .min = .{ low[0] - margin, low[1] - margin, low[2] - margin }, .max = .{ high[0] + margin, high[1] + margin, high[2] + margin } };
        self.each(world, reach, self, struct {
            fn visit(mobs: *Mobs, mob: Mob) anyerror!bool {
                if (mob.motion.resting) mobs.rouseMob(mob);
                return false;
            }
        }.visit) catch |err| {
            self.failure = err;
        };
    }

    /// Visits the mobs whose boxes meet a box, in the order EntitySectionStorage.getEntities
    /// finds them: columns by x, then by z as an unsigned field, each column's sections by y as
    /// one, and in each section as they came into it. `visit` returns whether to stop. Every
    /// query keeps its own round of places, so a visit may ask again.
    pub fn each(self: *Mobs, world: u32, query: body.Box, context: anytype, comptime visit: fn (@TypeOf(context), Mob) anyerror!bool) !void {
        if (self.active.count == 0) return;
        const Lookup = struct {
            mobs: *Mobs,
            query: body.Box,
            context: @TypeOf(context),

            fn each(lookup: *const @This(), entry: entities.space.Entry) anyerror!bool {
                const mobs = lookup.mobs;
                // The space gives only the mobs' kinds, each with its slot.
                const index = entry.slot;
                if (@import("builtin").mode == .debug) std.debug.assert(mobs.isMob(index));
                // Held only while visited; a visitor keeps ids, not mobs.
                const mob = try mobs.inSlot(index);
                if (mob.entity.removed or !living.box(mobs, mob).intersects(lookup.query)) return false;
                return visit(lookup.context, mob);
            }
        };
        const lookup: Lookup = .{ .mobs = self, .query = query, .context = context };
        try self.places.space.each(world, .{ .min = query.min, .max = query.max }, self.kinds, &lookup, Lookup.each);
    }

    /// The squared distance to the nearest player in the world who is not a spectator, as
    /// EntityGetter.getNearestPlayer with no range finds them.
    pub fn nearestPlayerDistanceSquared(self: *Mobs, world: u32, position: [3]f64) ?f64 {
        var best: ?f64 = null;
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (player.world != world or player.stage != .ready) continue;
            if (self.deps.player_states.of(player).gamemode == .spectator) continue;
            const dx = player.position.x - position[0];
            const dy = player.position.y - position[1];
            const dz = player.position.z - position[2];
            const distance = dx * dx + dy * dy + dz * dz;
            if (best == null or distance < best.?) best = distance;
        }
        return best;
    }

    /// LivingEntity.pushEntities: what is pushable by the mob and in its box, in the order the
    /// level finds it, after the cramming check, each pushing back as LivingEntity.doPush has it.
    /// How many it found, each of which wakes, as resting mobs skip their own query.
    pub fn pushEntities(self: *Mobs, mob: Mob) !u32 {
        const own = living.box(self, mob);
        const slot = self.slotOf(mob.entity.id).?;
        const collisions = self.deps.collisions;
        var found: Found = .{ .entities = self.deps.entities };
        try collisions.each(mob.motion.world, own, slot, .pushable, .{ .context = &found, .visit = Found.visit });
        if (found.all == 0) return 0;
        // The maxEntityCramming rule at its default: past 23, one tick in four, those that ride
        // nothing are counted, and past 23 of them it hurts. The hurt moves nothing.
        const cramming = 24;
        if (found.all > cramming - 1 and mob.idle.random.nextIntBounded(4) == 0 and found.free > cramming - 1) {
            _ = try self.hurt(mob, .{ .type = .cramming }, 6.0);
        }
        var pushing: Pushing = .{ .collisions = collisions, .mob = slot, .own = try mobPushable(self, slot) };
        try collisions.each(mob.motion.world, own, slot, .pushable, .{ .context = &pushing, .visit = Pushing.visit });
        return found.all;
    }

    /// What LivingEntity.pushEntities counts: all it found, and those that ride nothing.
    const Found = struct {
        entities: *entities.Entities,
        all: u32 = 0,
        free: u32 = 0,

        fn visit(context: *anyopaque, entry: entities.space.Entry, _: body.Box) anyerror!bool {
            const found: *Found = @ptrCast(@alignCast(context));
            found.all += 1;
            if (found.entities.vehicleOf(entry.slot) == null) found.free += 1;
            return false;
        }
    };

    /// LivingEntity.doPush: each found pushes back, Entity.push(the mob).
    const Pushing = struct {
        collisions: *EntityCollisions,
        mob: u32,
        /// The mob's own pushable box, null where it is not pushable, as on a ladder.
        own: ?body.Box,

        fn visit(context: *anyopaque, entry: entities.space.Entry, found: body.Box) anyerror!bool {
            const pushing: *Pushing = @ptrCast(@alignCast(context));
            try pushing.collisions.push(entry.slot, found, pushing.mob, pushing.own);
            return false;
        }
    };

    /// Where a mob is now.
    fn mobPosition(context: *anyopaque, slot: u32) [3]f64 {
        const self: *Mobs = @ptrCast(@alignCast(context));
        return (self.inSlot(slot) catch unreachable).motion.position;
    }

    /// Entity.push(x, y, z) on a mob: its velocity changes, and replication sends it.
    fn mobNudge(context: *anyopaque, slot: u32, by: [2]f64) void {
        const self: *Mobs = @ptrCast(@alignCast(context));
        const mob = self.inSlot(slot) catch unreachable;
        mob.motion.velocity[0] += by[0];
        mob.motion.velocity[2] += by[1];
        mob.entity.has_impulse = true;
    }

    /// A mob something pushable met wakes.
    fn mobTouched(context: *anyopaque, slot: u32) void {
        const self: *Mobs = @ptrCast(@alignCast(context));
        self.rouseHeld(slot, self.inSlot(slot) catch unreachable);
    }

    /// Where a player is now.
    fn playerPosition(context: *anyopaque, slot: u32) [3]f64 {
        const self: *Mobs = @ptrCast(@alignCast(context));
        const player = &self.deps.players.records[Players.playerOfEntity(self.deps.entities.directory.entry(slot).id)];
        return .{ player.position.x, player.position.y, player.position.z };
    }

    /// LivingEntity.isPickable for a mob: any not removed, its box.
    fn mobPickable(context: *anyopaque, slot: u32) anyerror!?body.Box {
        const self: *Mobs = @ptrCast(@alignCast(context));
        const mob = try self.inSlot(slot);
        if (mob.entity.removed) return null;
        return living.box(self, mob);
    }

    /// LivingEntity.isPushable for a mob: alive and off climbables, its box.
    fn mobPushable(context: *anyopaque, slot: u32) anyerror!?body.Box {
        const self: *Mobs = @ptrCast(@alignCast(context));
        const mob = try self.inSlot(slot);
        if (mob.entity.removed or !mob.alive() or try living.onClimbable(self, mob)) return null;
        return living.box(self, mob);
    }

    /// Player.isPickable: in the world and no spectator, its box.
    fn playerPickable(context: *anyopaque, slot: u32) anyerror!?body.Box {
        const self: *Mobs = @ptrCast(@alignCast(context));
        const player = &self.deps.players.records[Players.playerOfEntity(self.deps.entities.directory.entry(slot).id)];
        if (!player.inWorld() or self.deps.player_states.of(player).gamemode == .spectator) return null;
        return playerBox(player);
    }

    /// LivingEntity.isPushable for a player: in the world, alive, no spectator, off climbables.
    fn playerPushable(context: *anyopaque, slot: u32) anyerror!?body.Box {
        const self: *Mobs = @ptrCast(@alignCast(context));
        const player = &self.deps.players.records[Players.playerOfEntity(self.deps.entities.directory.entry(slot).id)];
        if (!player.inWorld()) return null;
        const state = self.deps.player_states.of(player);
        if (state.gamemode == .spectator or state.health <= 0) return null;
        const around = self.level(player.world);
        if (try body.climbableAt(&around, .{ mth.floor(player.position.x), mth.floor(player.position.y), mth.floor(player.position.z) })) return null;
        return playerBox(player);
    }

    /// Wakes a resting mob, one the plugin holds or a copy Debug checks run on.
    pub fn rouseMob(self: *Mobs, mob: Mob) void {
        if (self.inPool(mob)) return self.rouseHeld(self.slotOf(mob.entity.id).?, mob);
        mob.motion.resting = false;
    }

    /// pushable: what LivingEntity.pushEntities moves. same_species: mobs of the mob's own kind.
    /// living: every living mob, as getEntitiesOfClass(LivingEntity) finds them.
    pub const Nearness = enum { pushable, same_species, living };

    /// The other mobs whose boxes meet a box, in the order EntitySectionStorage.getEntities finds
    /// them: by section, then by when each came into its section. LivingEntity.isPushable keeps
    /// the living off climbables, and asking marks a climber as vanilla's check does.
    pub fn near(self: *Mobs, mob: Mob, query: body.Box, which: Nearness, context: anytype, comptime visit: fn (@TypeOf(context), Mob) anyerror!bool) !void {
        const Search = struct {
            mobs: *Mobs,
            mob: Mob,
            which: Nearness,
            context: @TypeOf(context),

            fn each(search: *const @This(), other: Mob) anyerror!bool {
                const mobs = search.mobs;
                if (other.entity.id == search.mob.entity.id) return false;
                switch (search.which) {
                    .pushable => if (!other.alive() or try living.onClimbable(mobs, other)) return false,
                    .same_species => if (other.entity.species != search.mob.entity.species) return false,
                    .living => {},
                }
                return visit(search.context, other);
            }
        };
        const search: Search = .{ .mobs = self, .mob = mob, .which = which, .context = context };
        try self.each(mob.motion.world, query, &search, Search.each);
    }

    /// FarmBlock.turnToDirt.
    pub fn trampleFarmland(self: *Mobs, world: u32, position: [3]i32, _: u16) !void {
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, @intCast(game_data.registry.blockStateId("minecraft:dirt").?));
    }

    /// TurtleEggBlock.decreaseEggs: the crack sound, then one egg fewer, or none left.
    pub fn crackTurtleEgg(self: *Mobs, world: u32, position: [3]i32, state: u16) !void {
        const pitch = 0.9 + self.level_random.nextFloat() * 0.2;
        self.blockSound(world, centerOf(position), .turtle_egg_break, 0.7, pitch);
        const name = game_data.registry.blockStateName(state).?;
        const eggs = propertyValue(name, "eggs") orelse return;
        if (eggs.len != 1 or eggs[0] <= '1') return self.deps.block_edits.destroyBlock(world, position);
        const fewer = withProperty(state, "eggs", &.{eggs[0] - 1}) orelse return;
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, fewer);
        self.effects.worldEvent(world, .{ .x = position[0], .y = position[1], .z = position[2] }, 2001, state);
    }

    /// Level.destroyBlock with drops, as a boat breaks a lily pad: the block's break effect, what
    /// its loot table drops with no tool, each as Block.popResource drops it from the level's
    /// random, then what fluid the block held, or air.
    pub fn breakBlock(self: *Mobs, world: u32, position: [3]i32) !void {
        const level_view = self.level(world);
        const state = try level_view.state(position[0], position[1], position[2]);
        const physics = game_data.physics.get(state);
        if (physics.air) return;
        self.effects.worldEvent(world, .{ .x = position[0], .y = position[1], .z = position[2] }, 2001, state);
        if (self.deps.loot.tables.blocks[game_data.registry.block_state_to_block[state]]) |table| {
            self.loot_scratch.reset();
            const context: loot.Context = .{ .items = self.deps.items.deps.definitions, .state = state, .location = .{ .world = world, .x = @floatFromInt(position[0]), .y = @floatFromInt(position[1]), .z = @floatFromInt(position[2]) }, .random = self.loot_random.random(), .scratch = &self.loot_scratch };
            var buffer: [loot.maximum_drops]loot.Drop = undefined;
            const drops = table.evaluate(&context, &buffer) catch |err| switch (err) {
                error.OutOfMemory, error.LootCapacity => &.{},
                else => return err,
            };
            var requests: [loot.maximum_drops]ItemEntities.Spawn = undefined;
            var spawned: [loot.maximum_drops]entities.Id = undefined;
            for (drops, requests[0..drops.len]) |drop, *request| {
                // Block.popResource: half an item's height under a point near the block's centre.
                const x = @as(f64, @floatFromInt(position[0])) + 0.5 + (self.level_random.nextDouble() * 0.5 - 0.25);
                const y = @as(f64, @floatFromInt(position[1])) + 0.5 + (self.level_random.nextDouble() * 0.5 - 0.25) - @as(f64, @as(f32, 0.25)) / 2.0;
                const z = @as(f64, @floatFromInt(position[2])) + 0.5 + (self.level_random.nextDouble() * 0.5 - 0.25);
                const dx = self.level_random.nextDouble() * 0.2 - 0.1;
                const dz = self.level_random.nextDouble() * 0.2 - 0.1;
                request.* = .{ .world = world, .position = .{ x, y, z }, .velocity = .{ dx, 0.2, dz }, .stack = .{ .item = try item_data.define(self.deps.inventories, drop.kind, drop.components), .count = @intCast(drop.count) } };
            }
            try self.deps.dropped.createMany(requests[0..drops.len], spawned[0..drops.len]);
        }
        // FluidState.createLegacyBlock: a waterlogged block leaves its water.
        const left: u16 = if (physics.fluid == .water and physics.amount == 8 and !physics.falling) @intCast(game_data.registry.blockStateId("minecraft:water[level=0]").?) else self.air_state;
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, left);
    }

    // Saving.

    const encoded_size = 160;

    fn encode(mob: *const MobState) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = @splat(0);
        var writer = std.Io.Writer.fixed(&bytes);
        writer.writeByte(1) catch unreachable;
        writer.writeByte(@backingInt(mob.entity.species)) catch unreachable;
        writer.writeInt(u128, mob.entity.uuid, .little) catch unreachable;
        writer.writeInt(u32, mob.motion.world, .little) catch unreachable;
        for (mob.motion.position ++ mob.motion.velocity) |value| writer.writeInt(u64, @bitCast(value), .little) catch unreachable;
        writer.writeInt(u32, @bitCast(mob.motion.yaw), .little) catch unreachable;
        writer.writeInt(u32, @bitCast(mob.motion.pitch), .little) catch unreachable;
        writer.writeInt(u64, @bitCast(mob.motion.fall_distance), .little) catch unreachable;
        writer.writeInt(i16, @intCast(std.math.clamp(mob.entity.fire_ticks, std.math.minInt(i16), std.math.maxInt(i16))), .little) catch unreachable;
        writer.writeInt(i16, @intCast(std.math.clamp(mob.living.air_supply, std.math.minInt(i16), std.math.maxInt(i16))), .little) catch unreachable;
        writer.writeByte(@intFromBool(mob.motion.on_ground)) catch unreachable;
        writer.writeInt(u32, @bitCast(mob.living.health), .little) catch unreachable;
        writer.writeInt(i16, @intCast(mob.living.hurt_time), .little) catch unreachable;
        writer.writeInt(i16, @intCast(mob.living.death_time), .little) catch unreachable;
        writer.writeInt(i32, mob.idle.age, .little) catch unreachable;
        const breeding = mob.rare.breeding orelse mob_state.Breeding{};
        writer.writeInt(i32, if (mob.rare.ageing) |ageing| ageing.forced_age else 0, .little) catch unreachable;
        writer.writeInt(i32, breeding.in_love, .little) catch unreachable;
        writer.writeInt(u128, breeding.love_cause orelse 0, .little) catch unreachable;
        writer.writeByte(@as(u8, @intFromBool(breeding.love_cause != null)) | @as(u8, @intFromBool(mob.control.persistence_required)) << 1 | @as(u8, @intFromBool(mob.control.left_handed)) << 2 | @as(u8, @intFromBool(mob.control.no_ai)) << 3) catch unreachable;
        writer.writeInt(u64, @bitCast(mob.living.follow_range_bonus), .little) catch unreachable;
        writer.writeByte(mob.cow.variant) catch unreachable;
        writer.writeInt(u64, mob.idle.random.state(), .little) catch unreachable;
        return bytes;
    }

    fn decode(entity: u64, bytes: []const u8) !MobState {
        if (bytes.len != encoded_size or bytes[0] != 1) return error.CorruptMob;
        var reader = std.Io.Reader.fixed(bytes[1..]);
        const species = std.enums.fromInt(Species, try reader.takeByte()) orelse return error.CorruptMob;
        const uuid = try reader.takeInt(u128, .little);
        const world = try reader.takeInt(u32, .little);
        var vectors: [6]f64 = undefined;
        for (&vectors) |*value| value.* = @bitCast(try reader.takeInt(u64, .little));
        const yaw: f32 = @bitCast(try reader.takeInt(u32, .little));
        const pitch: f32 = @bitCast(try reader.takeInt(u32, .little));
        const fall_distance: f64 = @bitCast(try reader.takeInt(u64, .little));
        const fire_ticks = try reader.takeInt(i16, .little);
        const air_supply = try reader.takeInt(i16, .little);
        const on_ground = try reader.takeByte();
        const health: f32 = @bitCast(try reader.takeInt(u32, .little));
        const hurt_time = try reader.takeInt(i16, .little);
        const death_time = try reader.takeInt(i16, .little);
        const age = try reader.takeInt(i32, .little);
        const forced_age = try reader.takeInt(i32, .little);
        const in_love = try reader.takeInt(i32, .little);
        const love_cause = try reader.takeInt(u128, .little);
        const flags = try reader.takeByte();
        const follow_range_bonus: f64 = @bitCast(try reader.takeInt(u64, .little));
        const variant = try reader.takeByte();
        const random_state = try reader.takeInt(u64, .little);
        for (vectors) |value| if (!std.math.isFinite(value)) return error.CorruptMob;
        if (!std.math.isFinite(yaw) or !std.math.isFinite(pitch) or !std.math.isFinite(health) or on_ground > 1) return error.CorruptMob;
        const position: [3]f64 = vectors[0..3].*;
        return .{
            .entity = .{
                .id = entity,
                .uuid = uuid,
                .species = species,
                .fire_ticks = fire_ticks,
            },
            .idle = .{
                .random = .restore(random_state),
                .head_yaw = yaw,
                .body_yaw = yaw,
                .age = age,
            },
            .motion = .{
                .world = world,
                .position = position,
                .old_position = position,
                .velocity = vectors[3..6].*,
                .yaw = yaw,
                .pitch = pitch,
                .old_yaw = yaw,
                .old_pitch = pitch,
                .fall_distance = fall_distance,
                .on_ground = on_ground != 0,
            },
            .living = .{
                .air_supply = air_supply,
                .health = health,
                .hurt_time = hurt_time,
                .death_time = death_time,
                .follow_range_bonus = follow_range_bonus,
            },
            .control = .{
                .persistence_required = flags & 2 != 0,
                .left_handed = flags & 4 != 0,
                .no_ai = flags & 8 != 0,
            },
            .rare = .{
                .ageing = if (forced_age != 0) .{ .forced_age = forced_age } else null,
                .breeding = if (in_love != 0 or flags & 1 != 0) .{ .in_love = in_love, .love_cause = if (flags & 1 != 0) love_cause else null } else null,
            },
            .cow = .{
                .variant = variant,
            },
        };
    }

    /// Mobs are kept under the column each stood in when saved, so a column comes back with one
    /// scan: written as their column leaves memory and at checkpoints, read as it comes back.
    const record_prefix = 3;
    /// Before, they were kept by id alone, and all came into memory at once.
    const old_prefix = 1;

    /// Where a mob's record lies in the store, once it has been saved.
    const Stored = struct { column: entities.Column = .{ .world = 0, .x = 0, .z = 0 }, kept: bool = false };

    /// Records kept by id are moved under their columns, a scan's worth at a time.
    fn migrate(self: *Mobs) !void {
        while (true) {
            var after: [9]u8 = undefined;
            var cursor: records.ScanCursor = .{ .after = &after, .before = &.{old_prefix + 1} };
            var keys: [16][9]u8 = undefined;
            var values: [16][encoded_size]u8 = undefined;
            var entries: [16]records.ScanEntry = undefined;
            for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
            const found = try self.table.scan(&cursor, &entries);
            if (found.count == 0) return;
            var batch: entities.durable.Batch(encoded_size) = .{ .table = self.table };
            var gone: [16]records.Write = undefined;
            for (entries[0..found.count], &gone) |entry, *write| {
                if (entry.key_len != 9 or entry.key[0] != old_prefix) return error.CorruptMob;
                const entity = std.mem.readInt(u64, entry.key[1..9], .big);
                const restored = try decode(entity, entry.value[0..entry.value_len]);
                if (self.deps.worlds.get(restored.motion.world) == null) return error.CorruptMob;
                try batch.put(entities.durable.key(record_prefix, entities.space.columnOf(restored.motion.world, restored.motion.position), entity), entry.value[0..entry.value_len]);
                write.* = .{ .key = entry.key[0..9], .value = null };
            }
            try batch.flush();
            try self.table.putBatch(gone[0..found.count]);
        }
    }

    /// A column came into memory: its mobs come back from the store. One whose column left a
    /// moment ago and is still going stays; a record left behind by a mob since gone elsewhere is
    /// passed over.
    fn loadColumn(self: *Mobs, column: entities.Column) anyerror!void {
        var reader: entities.durable.ColumnReader(encoded_size) = .init(self.table, record_prefix, column);
        var rows: [16]entities.durable.ColumnReader(encoded_size).Row = undefined;
        while (true) {
            const found = try reader.next(&rows);
            if (found.len == 0) return;
            for (found) |row| try self.loadRow(column, row.id, row.value);
        }
    }

    fn loadRow(self: *Mobs, column: entities.Column, entity: u64, value: []const u8) !void {
        if (self.slotOf(entity)) |index| {
            const mob = try self.inSlot(index);
            if (!mob.entity.unloaded) return;
            mob.entity.unloaded = false;
            mob.entity.removed = false;
            try self.locate(index);
            return;
        }
        const restored = try decode(entity, value);
        if (self.deps.worlds.get(restored.motion.world) == null) return error.CorruptMob;
        _ = try self.insert(restored);
        self.trackingOf(self.slotOf(entity).?).stored = .{ .column = column, .kept = true };
    }

    /// Where nothing follows the loaded domain, every mob kept comes into memory at once.
    fn loadAll(self: *Mobs) !void {
        var reader: entities.durable.ColumnReader(encoded_size) = .all(self.table, record_prefix);
        var rows: [16]entities.durable.ColumnReader(encoded_size).Row = undefined;
        while (true) {
            const found = try reader.next(&rows);
            if (found.len == 0) return;
            for (found, reader.keys[0..found.len]) |row, key| try self.loadRow(entities.durable.columnOf(&key), row.id, row.value);
        }
    }

    /// A column left memory: its mobs are saved under it and go, told to their viewers as gone
    /// and let go once they are.
    fn unloadColumn(self: *Mobs, column: entities.Column) anyerror!void {
        var leaving: [64]u64 = undefined;
        while (true) {
            // Taken a run at a time, as each leaving changes the column.
            var count: usize = 0;
            var walk = self.places.space.entries(column, self.kinds);
            while (count < leaving.len) {
                const entry = walk.next() orelse break;
                leaving[count] = entry.id;
                count += 1;
            }
            if (count == 0) return;
            var batch: entities.durable.Batch(encoded_size) = .{ .table = self.table };
            for (leaving[0..count]) |entity| {
                const index = self.slotOf(entity) orelse return error.CorruptMob;
                const mob = try self.inSlot(index);
                self.trackingOf(index).idling = false;
                var state = mob.state();
                try self.save(&batch, index, &state);
                mob.entity.unloaded = true;
                mob.entity.removed = true;
                try self.locate(index);
            }
            try batch.flush();
        }
    }

    /// A mob's record put under the column it stands in, the one it left behind removed.
    fn save(self: *Mobs, batch: *entities.durable.Batch(encoded_size), index: u32, state: *const MobState) !void {
        const here = entities.space.columnOf(state.motion.world, state.motion.position);
        const stored = &self.trackingOf(index).stored;
        if (stored.kept and !std.meta.eql(stored.column, here)) try batch.delete(entities.durable.key(record_prefix, stored.column, state.entity.id));
        try batch.put(entities.durable.key(record_prefix, here, state.entity.id), &encode(state));
        stored.* = .{ .column = here, .kept = true };
    }

    /// A removed mob's record goes from the store, if it has one.
    fn forgetRecord(self: *Mobs, index: u32, entity: u64) !void {
        const stored = &self.trackingOf(index).stored;
        if (!stored.kept) return;
        var batch: entities.durable.Batch(encoded_size) = .{ .table = self.table };
        try batch.delete(entities.durable.key(record_prefix, stored.column, entity));
        try batch.flush();
        stored.kept = false;
    }

    /// Saves every mob in memory, and removes the records of the removed whose viewers are not yet
    /// told. Those whose columns left were saved as they did.
    pub fn checkpoint(self: *Mobs, space: storage.Space) !void {
        errdefer space.fail();
        var batch: entities.durable.Batch(encoded_size) = .{ .table = self.table };
        for (0..self.active.count) |active_at| {
            const index = self.active.at(active_at);
            var current = try self.copyAt(@intCast(index));
            if (current.entity.removed) {
                if (current.entity.unloaded) continue;
                const stored = &self.trackingOf(index).stored;
                if (stored.kept) try batch.delete(entities.durable.key(record_prefix, stored.column, current.entity.id));
                stored.kept = false;
                continue;
            }
            try self.save(&batch, @intCast(index), &current);
        }
        try batch.flush();
    }
};

test "mob records round trip" {
    var random = JavaRandom.init(7);
    const original: MobState = .{
        .idle = .{ .random = random, .age = -100 },
        .motion = .{
            .world = 1,
            .position = .{ 1.5, 64, -3.25 },
            .old_position = .{ 1.5, 64, -3.25 },
            .velocity = .{ 0, -0.0784, 0 },
            .yaw = 90,
        },
        .entity = .{
            .id = 5,
            .uuid = 0x1234,
            .species = .cow,
        },
        .living = .{
            .health = 7.5,
        },
        .rare = .{ .breeding = .{ .in_love = 30, .love_cause = 99 } },
        .cow = .{
            .variant = 2,
        },
    };
    _ = random.nextInt();
    const decoded = try Mobs.decode(5, &Mobs.encode(&original));
    try std.testing.expectEqual(original.motion.position, decoded.motion.position);
    try std.testing.expectEqual(original.living.health, decoded.living.health);
    try std.testing.expectEqual(original.rare.breeding.?.love_cause, decoded.rare.breeding.?.love_cause);
    try std.testing.expectEqual(original.idle.random.state(), decoded.idle.random.state());
}

test "mobs draw UUIDs of their own across restarts" {
    // Each start used to draw the same first UUIDs from a fixed seed; ids never repeat.
    var seen: [256]u128 = undefined;
    for (&seen, 0..) |*uuid, entity| {
        var random = Mobs.entityRandom(0x6d6f6273, 12000 + entity);
        uuid.* = Mobs.randomUuid(&random);
    }
    std.sort.pdq(u128, &seen, {}, std.sort.asc(u128));
    for (seen[1..], seen[0 .. seen.len - 1]) |uuid, previous| try std.testing.expect(uuid != previous);
}

fn mth_floor(value: f64) i32 {
    return @intFromFloat(@floor(value));
}

/// What the mobs keep of each mob beside its state: whether it idles and the look an idle
/// tick keeps, whether its column ticks, and where its record lies in the store.
const Tracking = struct {
    idling: bool = false,
    gaze_yaw: f32 = 0,
    /// Began idling since replication last sent the mob in full, which it does once to catch
    /// anything that changed on the way in; then it sends on the ticks the phase says.
    fresh: bool = false,
    send_phase: u8 = 0,
    column: ColumnTicks = .{},
    /// The domains revision as of which its column did not tick, so it waits unread.
    dormant_revision: u64 = std.math.maxInt(u64),
    stored: Mobs.Stored = .{},
};

/// A row of the mobs' table: each group of a mob's state a column, and what the mobs keep beside.
const Row = struct {
    idle: mob_state.Idle,
    motion: mob_state.Motion,
    entity: mob_state.EntityPart,
    living: mob_state.Living,
    control: mob_state.Control,
    goals: mob_state.Goals,
    navigation: mob_state.Navigation,
    cow: mob_state.CowPart,
    tracking: Tracking,
    /// The link to the mob's rare parts in `extras`, or none.
    extras: u32,
};
pub const Table = entities.KindTable(Row);

const ColumnTicks = struct { revision: u64 = std.math.maxInt(u64), world: u32 = 0, chunk: [2]i32 = .{ 0, 0 }, ticks: bool = false };

const WorldView = struct { world: u32, level: body.Level, ultrawarm: bool };

/// The chunk column a position is in.
pub fn chunkOf(position: [3]f64) [2]i32 {
    return .{ @divFloor(mth_floor(position[0]), 16), @divFloor(mth_floor(position[2]), 16) };
}

/// Nodes one path search may make. A cow visits at most 285 and makes a few per visit.
const search_nodes = 16384;
/// Nodes one path may hold: the most a search can visit, plus its start.
const path_capacity = 320;

fn centerOf(position: [3]i32) [3]f64 {
    return .{ @as(f64, @floatFromInt(position[0])) + 0.5, @as(f64, @floatFromInt(position[1])) + 0.5, @as(f64, @floatFromInt(position[2])) + 0.5 };
}

fn propertyValue(name: []const u8, key: []const u8) ?[]const u8 {
    const begin = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    var properties = std.mem.splitScalar(u8, name[begin + 1 .. name.len - 1], ',');
    while (properties.next()) |entry| {
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..separator], key)) return entry[separator + 1 ..];
    }
    return null;
}

/// The state with one property changed, found by name, for the rare edits mobs make.
fn withProperty(state: u16, key: []const u8, value: []const u8) ?u16 {
    const name = game_data.registry.blockStateName(state).?;
    var buffer: [256]u8 = undefined;
    const begin = std.mem.indexOfScalar(u8, name, '[') orelse return null;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.writeAll(name[0 .. begin + 1]) catch return null;
    var properties = std.mem.splitScalar(u8, name[begin + 1 .. name.len - 1], ',');
    var first = true;
    while (properties.next()) |entry| {
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
        if (!first) writer.writeByte(',') catch return null;
        first = false;
        if (std.mem.eql(u8, entry[0..separator], key)) {
            writer.print("{s}={s}", .{ key, value }) catch return null;
        } else writer.writeAll(entry) catch return null;
    }
    writer.writeByte(']') catch return null;
    const found = game_data.registry.blockStateId(writer.buffered()) orelse return null;
    return @intCast(found);
}

/// A player's box, standing or sneaking, as its pose makes it.
pub fn playerBox(player: *const PlayerRecord) body.Box {
    return body.makeBox(.{ player.position.x, player.position.y, player.position.z }, 0.6, if (player.flags.sneaking) 1.5 else 1.8);
}
