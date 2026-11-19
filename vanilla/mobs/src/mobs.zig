//! The mobs of every world, in a fixed array with a grid of where they stand, ticked in vanilla's order
//! where the ticking domain reaches and saved at checkpoints. Mobs read blocks through copies
//! of the sections they touch, kept across ticks.

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
const Domains = @import("domains").domains.Domains;
const world_effects = @import("vanilla_blocks").world_effects;
const body = @import("vanilla_bodies").body;
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
const grid_state = @import("grid.zig");
const goals = @import("goals.zig");
const inventories = @import("inventories");
const Lighting = @import("terrain").lighting.Lighting;
const LightSample = @import("terrain").lighting.Sample;
const Time = @import("vanilla_world").time.Time;
const Weather = @import("vanilla_world").weather.Weather;
const Items = @import("vanilla_items").items.Items;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const Experience = @import("vanilla_survival").experience.Experience;
const Loot = @import("vanilla_items").loot_registry.Loot;
const loot = @import("vanilla_items").loot;
const item_data = @import("vanilla_items").item_data;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const Furnaces = @import("vanilla_crafting").furnaces.Furnaces;
const EnchantmentRegistry = @import("vanilla_items").enchantment_registry.EnchantmentRegistry;
const damage = @import("damage.zig");

const Mob = mob_state.Mob;
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
        /// Mobs in every world together, alive or dying.
        maximum: usize = 1024,
        /// Sections of blocks mobs keep decoded across ticks.
        copies: u32 = 512,
        /// Block edits held for paths to answer in a batch, from the first that changes a
        /// collision. Edits past it are counted and go unanswered.
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
        loot: *Loot,
        dropped: *ItemEntities,
        furnaces: *Furnaces,
        enchantment_registry: *EnchantmentRegistry,
    };

    deps: Dependencies,
    config: Configuration,
    mobs: []Mob,
    /// Mobs by the cell they stand in, and where and when they came into their section.
    grid: grid_state.Grid,
    arrivals: []grid_state.Arrival,
    arrival_stamp: u64 = 0,
    /// Room for what a query near a box finds.
    nearby: []u32,
    /// Half the width of the widest mob, which a box query reaches out by.
    widest_half: f64,
    ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    active: lightning_rod.system.IndexSet,
    free: []u32,
    free_count: usize,
    blocks: *mob_blocks.MobBlocks,
    copies: *chunks.Copies,
    species: [@typeInfo(Species).@"enum".field_names.len]species_data.Traits,
    /// The level's random, which a few block reactions draw from.
    level_random: JavaRandom,
    /// Seeds for new mobs' randoms, as RandomSupport.generateUniqueSeed gives each entity its own.
    seeds: std.Random.DefaultPrng,
    /// Seeds of sound packets, which vanilla draws from a separate random that nothing else reads.
    sound_seeds: std.Random.DefaultPrng,
    effects: world_effects.Effects,
    table: records.Table,
    /// Mobs saved at the last checkpoint, to remove the ones gone since.
    saved: []u64,
    saved_count: usize = 0,
    air_state: u16,
    /// The working memory of path searches, one at a time on the simulation thread.
    search: pathfinding.Search,
    /// Each mob's path, at its index, path_capacity nodes apiece.
    paths: []pathfinding.PathNode,
    /// Edits since the first that changed a collision, which paths answer in a batch, in order.
    edits: []body.Edit,
    edit_count: usize = 0,
    /// Edits past the capacity, which no path answers.
    edits_dropped: u64 = 0,
    /// Path searches run, and recomputations edits asked for, for measuring.
    path_searches: u64 = 0,
    edit_recomputes: u64 = 0,
    /// Travels resting mobs skipped, and travels run, for measuring.
    travels_skipped: u64 = 0,
    travels_run: u64 = 0,
    /// Ticks idle mobs took in the herd, for measuring.
    idle_ticks: u64 = 0,
    /// Blocks of eight idle mobs advanced together, and lanes in them left to the scalar tick.
    idle_blocks: u64 = 0,
    rare_lanes: u64 = 0,
    /// Mobs following a path while a batch of edits is answered.
    candidates: []u32,
    /// Blocks as they stood after the edit being answered, which levels read while it is set.
    overlay: body.Overlay,
    overlay_view: ?*const body.Overlay = null,
    /// The blocks around the awake mob ticking, which levels read while it is set.
    window: body.Window = .{},
    window_view: ?*const body.Window = null,
    /// Room a move and its block effects work in, reused by every mob.
    colliders: body.Colliders = .{},
    effects_scratch: @import("block_effects.zig").Scratch = .{},
    /// By player slot, whether the player holds cow food in either hand, noted as mobs start
    /// ticking: tempting asks every other tick for every mob, and hands change only between.
    holding_food: []bool,
    /// Mobs in entity id order, the order they tick in, with idle mobs' hot state.
    herd: herd_state.Herd,
    /// The players idle mobs look for this tick.
    present: []herd_state.Audience.Player,
    present_count: usize = 0,
    holders: []herd_state.Audience.Player,
    holder_count: usize = 0,
    /// Set while Debug checks an idle tick against the full one, which then plays no sound.
    muted: bool = false,
    /// Rises whenever columns start or stop ticking.
    domain_revision: u64 = 0,
    /// By slot, whether the mob's column ticked, as of a domains revision.
    column_ticks: []ColumnTicks,
    /// Worlds' levels found this tick, kept only while mobs tick.
    views: [8]WorldView = undefined,
    view_count: usize = 0,
    ticking: bool = false,
    /// Entity.movementThisTick for the mob ticking, which only it adds to and reads.
    movements: [8]mob_state.Movement = undefined,
    /// The last path found, until a navigation takes it.
    scratch_path: []pathfinding.PathNode,
    scratch: struct { count: u16 = 0, target: [3]i32 = .{ 0, 0, 0 }, reached: bool = false } = .{},
    /// The cow_food item tag and the panic_causes damage type tag, read when definitions change.
    food_tag: ?content_tags.Tags.Id = null,
    /// Loot tables draw from their own random, as each vanilla table has its own sequence.
    loot_random: std.Random.DefaultPrng,
    loot_scratch: std.heap.FixedBufferAllocator,
    /// By damage type: what its tags say, and its id in the registry.
    damage_flags: []damage.Flags,
    damage_ids: []i32,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Mobs {
        const self = try allocate(allocator, config, deps);
        try self.load();
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Mobs {
        if (config.maximum == 0 or config.maximum > 65536) return error.InvalidMobCapacity;
        if (config.edits == 0) return error.InvalidEditCapacity;
        const self = try allocator.create(Mobs);
        self.* = .{
            .deps = deps,
            .config = config,
            .mobs = try allocator.alloc(Mob, config.maximum),
            .grid = try .init(allocator, config.maximum),
            .arrivals = try allocator.alloc(grid_state.Arrival, config.maximum),
            .nearby = try allocator.alloc(u32, config.maximum),
            .widest_half = 0,
            .active = try .init(allocator, config.maximum),
            .free = try allocator.alloc(u32, config.maximum),
            .free_count = config.maximum,
            .blocks = try mob_blocks.MobBlocks.init(allocator, deps.block_definitions),
            .copies = try chunks.Copies.init(allocator, deps.chunks, config.copies),
            .species = undefined,
            .level_random = .init(@bitCast(config.seed)),
            .seeds = .init(config.seed ^ 0x73656564),
            .sound_seeds = .init(config.seed ^ 0x736f756e64),
            .loot_random = .init(config.seed ^ 0x6c6f6f74),
            .loot_scratch = .init(try allocator.alloc(u8, 16 * 1024)),
            .effects = try .init(allocator, deps.players),
            .table = records.Table.init(deps.storage, deps.record_workspaces.resources),
            .saved = try allocator.alloc(u64, config.maximum),
            .air_state = @intCast(game_data.registry.blockStateId("minecraft:air").?),
            .search = try .init(allocator, search_nodes),
            .paths = try allocator.alloc(pathfinding.PathNode, config.maximum * path_capacity),
            .scratch_path = try allocator.alloc(pathfinding.PathNode, path_capacity),
            .edits = try allocator.alloc(body.Edit, config.edits),
            .candidates = try allocator.alloc(u32, config.maximum),
            .holding_food = try allocator.alloc(bool, deps.players.records.len),
            .column_ticks = try allocator.alloc(ColumnTicks, config.maximum),
            .herd = try .init(allocator, config.maximum),
            .present = try allocator.alloc(herd_state.Audience.Player, deps.players.records.len),
            .holders = try allocator.alloc(herd_state.Audience.Player, deps.players.records.len),
            .overlay = try .init(allocator, config.edits),
            .damage_flags = try allocator.alloc(damage.Flags, @typeInfo(mob_state.DamageType).@"enum".field_names.len),
            .damage_ids = try allocator.alloc(i32, @typeInfo(mob_state.DamageType).@"enum".field_names.len),
        };
        self.copies.mark(self.blocks.marks);
        try self.readTags();
        try deps.items.deps.definitions.registry.onChange(self, readTags);
        try deps.chunks.observe(.init(self, blocksChanged));
        try deps.domains.observe(.init(Mobs, self, domainsChanged));
        try deps.client.registry.onChange(self, readTags);
        for (self.free, 0..) |*slot, index| slot.* = @intCast(config.maximum - 1 - index);
        inline for (@typeInfo(Species).@"enum".field_names, 0..) |field, index| self.species[index] = species_data.traits(@field(Species, field));
        for (self.species) |species| self.widest_half = @max(self.widest_half, @as(f64, species.width) / 2);
        try self.ids.ensureTotalCapacity(allocator, @intCast(config.maximum));
        return self;
    }

    pub fn traits(self: *const Mobs, species: Species) *const species_data.Traits {
        return &self.species[@backingInt(species)];
    }

    pub fn level(self: *Mobs, world: u32) body.Level {
        var result = self.view(world).level;
        result.overlay = self.overlay_view;
        result.window = self.window_view;
        result.colliders = &self.colliders;
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
            .level = .{
                .copies = self.copies,
                .blocks = self.blocks,
                .world = world,
                .minimum_y = definition.dimension.minimumSection() * 16,
                .height = @intCast(definition.dimension.sectionCount() * 16),
                .air = self.air_state,
            },
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

    pub fn canSpawn(self: *const Mobs) bool {
        return self.free_count > 0;
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
        if (self.free_count == 0) return error.MobCapacity;
        const entity = try self.deps.entities.reserveIds(1);
        if (entity > std.math.maxInt(i32)) return error.IdExhausted;
        var random = entityRandom(self.config.seed, entity);
        const traits_entry = self.traits(request.species);
        var created: Mob = .{
            .id = entity,
            .uuid = randomUuid(&random),
            .species = request.species,
            .world = request.world,
            .position = request.position,
            .old_position = request.position,
            .random = random,
            .health = @floatCast(traits_entry.attribute(.max_health)),
            .yaw = request.yaw,
            .old_yaw = request.yaw,
            .head_yaw = request.yaw,
            .body_yaw = request.yaw,
            .variant = request.variant,
        };
        if (request.finalize) {
            // Mob.finalizeSpawn: a random bonus to the follow range, then the left hand chance.
            created.follow_range_bonus = self.level_random.triangle(0.0, 0.11485000000000001);
            created.left_handed = self.level_random.nextFloat() < 0.05;
        } else {
            // LivingEntity's constructor turns the head by Math.random in radians, read as degrees,
            // and snapTo leaves it while the body faces the given yaw.
            created.head_yaw = @floatCast(@as(f64, @floatFromInt(self.seeds.next() >> 11)) / (1 << 53) * @as(f64, @as(f32, std.math.pi * 2.0)));
        }
        if (request.baby) created.age = -24000;
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

    fn insert(self: *Mobs, created: Mob) !u64 {
        assert(self.free_count > 0);
        assert(self.active.values().len + self.free_count == self.mobs.len);
        self.free_count -= 1;
        const index = self.free[self.free_count];
        self.mobs[index] = created;
        self.ids.putAssumeCapacityNoClobber(created.id, index);
        self.active.insert(index);
        self.herd.add(self.mobs, index);
        self.arrivals[index] = .{ .section = sectionOf(created.position), .stamp = self.nextArrival() };
        self.column_ticks[index] = .{};
        self.locate(index);
        // A mob appearing touches the mobs around it.
        const placed = living.box(self, &self.mobs[index]);
        self.wake(created.world, placed.min, placed.max);
        return created.id;
    }

    /// Keeps a mob in the grid cell it stands in, and notes when it comes into a new section.
    pub fn locate(self: *Mobs, index: u32) void {
        const mob = &self.mobs[index];
        if (mob.removed) return self.grid.remove(index);
        const section = sectionOf(mob.position);
        if (!std.meta.eql(section, self.arrivals[index].section)) self.arrivals[index] = .{ .section = section, .stamp = self.nextArrival() };
        self.grid.place(index, grid_state.Grid.cellOf(mob.world, mob.position[0], mob.position[2]), living.box(self, mob));
    }

    fn nextArrival(self: *Mobs) u64 {
        self.arrival_stamp += 1;
        return self.arrival_stamp;
    }

    /// Forgets a removed mob. Its viewers have been told, so the slot is free.
    pub fn release(self: *Mobs, index: u32) void {
        const mob = &self.mobs[index];
        assert(mob.removed);
        self.grid.remove(index);
        assert(self.ids.remove(mob.id));
        self.active.remove(index);
        self.herd.remove(index);
        self.free[self.free_count] = index;
        self.free_count += 1;
    }

    /// A mob for systems outside the tick, which may change it, so it stops idling first.
    pub fn get(self: *Mobs, entity: u64) ?*Mob {
        const index = self.ids.get(entity) orelse return null;
        self.stopIdling(index);
        // It may be moved, so whether it ticks is asked again.
        const place = self.herd.place_of[index];
        if (place != herd_state.no_place) self.herd.still.dormant_revision[place] = std.math.maxInt(u64);
        return &self.mobs[index];
    }

    /// The mob's hot fields go back to it from the herd, if it idles.
    fn stopIdling(self: *Mobs, index: u32) void {
        const place = self.herd.place_of[index];
        if (place != herd_state.no_place and self.herd.idling[place]) self.herd.leave(place, &self.mobs[index]);
    }

    /// Whether the mob idles in the herd, so nothing about it changes but its counters.
    pub fn idles(self: *const Mobs, index: usize) bool {
        const place = self.herd.place_of[index];
        return place != herd_state.no_place and self.herd.idling[place];
    }

    /// Wakes a resting mob, which then ticks in full.
    pub fn rouse(self: *Mobs, index: u32) void {
        self.stopIdling(index);
        self.mobs[index].resting = false;
    }

    pub fn tick(self: *Mobs) !void {
        self.tickViews(true);
        defer self.tickViews(false);
        try self.noteHeldFood();
        defer self.copies.endTick();
        try self.answerEdits();
        self.herd.tidy(self.mobs);
        const audience = self.noteAudience();
        const cow = self.traits(.cow);
        const species: herd_state.Species = .{ .tempt_range = cow.attribute(.tempt_range), .eye_height = cow.eye_height, .ambient_interval = cow.ambient_interval };
        var context: TickContext = .{ .audience = audience, .species = species, .volume = cow.sound_volume };
        // ServerLevel's entity tick list, by entity id. Runs of eight idle mobs advance at once.
        var place: usize = 0;
        while (place < self.herd.count) {
            if (place + herd_state.lane_count <= self.herd.count and self.idleRun(place, &context.ticking)) {
                try self.tickBlock(place, &context);
                place += herd_state.lane_count;
                continue;
            }
            try self.tickPlace(place, &context);
            place += 1;
        }
    }

    const TickContext = struct {
        audience: herd_state.Audience,
        species: herd_state.Species,
        volume: f32,
        ticking: TickingMemo = .{},
    };

    /// Whether an idle mob's column ticks, which holds until the domains change.
    fn idleTicks(self: *Mobs, place: usize, ticking: *TickingMemo) bool {
        const still = &self.herd.still;
        if (still.ticks_revision[place] != self.domain_revision) {
            still.ticks[place] = ticking.ticks(self, still.world[place], still.chunk[place]);
            still.ticks_revision[place] = self.domain_revision;
        }
        return still.ticks[place];
    }

    /// Whether the eight places from one are all idle mobs that tick.
    fn idleRun(self: *Mobs, first: usize, ticking: *TickingMemo) bool {
        for (first..first + herd_state.lane_count) |place| {
            if (self.herd.slots[place] == herd_state.no_place or !self.herd.idling[place]) return false;
            if (!self.idleTicks(place, ticking)) return false;
        }
        return true;
    }

    fn tickBlock(self: *Mobs, first: usize, context: *TickContext) !void {
        var before: [herd_state.lane_count]Mob = undefined;
        if (verify_idle) for (&before, 0..) |*lane, offset| {
            lane.* = self.idleBefore(first + offset);
        };
        const block = herd_state.advanceBlock(&self.herd, first, context.audience, context.species);
        self.idle_blocks += 1;
        if (!block.any_rare) {
            herd_state.commitBlock(&self.herd, first, &block);
            self.idle_ticks += herd_state.lane_count;
            if (verify_idle) for (before, 0..) |lane, offset| try self.checkIdle(first + offset, lane);
            return;
        }
        // In order: a rare lane takes its own tick, which may wake the lanes after it.
        for (0..herd_state.lane_count) |offset| {
            const place = first + offset;
            if (block.rare[offset] or !self.herd.idling[place]) {
                if (block.rare[offset]) self.rare_lanes += 1;
                try self.tickPlace(place, context);
                continue;
            }
            herd_state.commitLane(&self.herd, first, &block, offset);
            self.idle_ticks += 1;
            if (verify_idle) try self.checkIdle(place, before[offset]);
        }
    }

    fn tickPlace(self: *Mobs, place: usize, context: *TickContext) !void {
        const index = self.herd.slots[place];
        if (index == herd_state.no_place) return;
        // An idle mob is read from the herd alone, without touching its Mob.
        if (self.herd.idling[place]) {
            if (!self.idleTicks(place, &context.ticking)) return;
            const before = if (verify_idle) self.idleBefore(place) else {};
            switch (herd_state.advance(&self.herd, place, context.audience, context.species)) {
                .idled => |sound| {
                    self.idle_ticks += 1;
                    // Mob.playAmbientSound, once the tick is sure to stand.
                    if (sound) |pitch| {
                        const still = &self.herd.still;
                        const at = still.position[place];
                        self.effects.sound(still.world[place], .{ .x = at[0], .y = at[1], .z = at[2] }, Sound.cow_ambient.name(), .neutral, context.volume, pitch, @bitCast(self.sound_seeds.next()), null);
                    }
                    if (verify_idle) try self.checkIdle(place, before);
                    return;
                },
                // Something starts, so the mob takes its full tick from the start.
                .started => self.herd.leave(place, &self.mobs[index]),
            }
        }
        if (self.herd.still.dormant_revision[place] == self.domain_revision) return;
        const mob = &self.mobs[index];
        if (mob.removed) return;
        if (!self.columnTicks(index, &context.ticking)) {
            self.herd.still.dormant_revision[place] = self.domain_revision;
            return;
        }
        // An awake mob reads the blocks around it many times over, so they are read once. A resting
        // one reads almost none.
        if (!mob.resting) {
            const around = self.level(mob.world);
            try self.window.fill(&around, mob.blockPosition());
            self.window_view = &self.window;
        }
        {
            defer self.window_view = null;
            try mob_tick.tick(self, mob);
        }
        self.locate(index);
        // Blocks the mob changed, as trampled farmland, before the next mob moves.
        try self.answerEdits();
        if (!self.herd.idling[place] and herd_state.idle(self, mob)) self.herd.enter(place, mob);
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

    fn idleBefore(self: *Mobs, place: usize) Mob {
        var before = self.mobs[self.herd.slots[place]];
        self.herd.writeBack(place, &before);
        return before;
    }

    fn checkIdle(self: *Mobs, place: usize, before: Mob) !void {
        var expected = before;
        // The full tick on the copy plays nothing, as the idle tick already did.
        self.muted = true;
        defer self.muted = false;
        try mob_tick.tick(self, &expected);
        var actual = self.mobs[self.herd.slots[place]];
        self.herd.writeBack(place, &actual);
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("idle tick diverged for mob {d}\n", .{actual.id});
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
    fn columnTicks(self: *Mobs, index: u32, ticking: *TickingMemo) bool {
        const mob = &self.mobs[index];
        const chunk = chunkOf(mob.position);
        const known = &self.column_ticks[index];
        if (known.revision == self.domain_revision and known.world == mob.world and std.meta.eql(known.chunk, chunk)) return known.ticks;
        known.* = .{ .revision = self.domain_revision, .world = mob.world, .chunk = chunk, .ticks = ticking.ticks(self, mob.world, chunk) };
        return known.ticks;
    }

    fn domainsChanged(self: *Mobs, _: []const @import("domains").domains.Column, _: []const @import("domains").domains.Column) void {
        self.domain_revision += 1;
    }

    /// ServerLevel.sendBlockUpdated, first half. Edits come here after they apply, a batch at a
    /// time, with what they replaced. From the first that changes a collision shape on, every edit
    /// is kept until the next answer, so each path that recomputes can see the world as it stood.
    fn blocksChanged(self: *Mobs, section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
        if (self.active.values().len == 0) return;
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
        for (edits, previous) |edit, old| {
            const collision = self.blocks.get(old).collision != self.blocks.get(edit.state).collision;
            if (!collision and self.edit_count == 0) continue;
            if (self.edit_count == self.edits.len) {
                self.edits_dropped += 1;
                continue;
            }
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
    fn answerEdits(self: *Mobs) !void {
        if (self.edit_count == 0) return;
        defer self.edit_count = 0;
        var candidate_count: usize = 0;
        for (self.active.values()) |index| {
            const mob = &self.mobs[index];
            if (mob.removed or navigation.done(mob) or mob.navigation.has_delayed_recomputation) continue;
            if (!self.loaded(mob.world, mob.blockPosition())) continue;
            self.candidates[candidate_count] = @intCast(index);
            candidate_count += 1;
        }
        if (candidate_count == 0) return;
        defer self.overlay_view = null;
        var laid_after: ?usize = null;
        for (self.edits[0..self.edit_count], 0..) |edit, at| {
            if (!edit.collision) continue;
            for (self.candidates[0..candidate_count]) |index| {
                const mob = &self.mobs[index];
                if (mob.world != edit.world or !navigation.shouldRecomputePath(self, mob, edit.position)) continue;
                if (laid_after != at) {
                    self.layOver(at);
                    laid_after = at;
                }
                self.edit_recomputes += 1;
                try navigation.recomputePath(self, mob, edit.game_time);
            }
        }
    }

    fn layOver(self: *Mobs, at: usize) void {
        self.overlay.layAfter(self.edits[0..self.edit_count], at);
        self.overlay_view = if (self.overlay.states.count() == 0) null else &self.overlay;
    }

    /// The game time, Level.getGameTime, which navigation times stalls and recomputations by.
    pub fn gameTime(self: *const Mobs) i64 {
        return self.deps.time.game_time;
    }

    pub fn indexOf(self: *const Mobs, mob: *const Mob) usize {
        return (@intFromPtr(mob) - @intFromPtr(self.mobs.ptr)) / @sizeOf(Mob);
    }

    pub fn pathNodes(self: *Mobs, mob: *const Mob) []pathfinding.PathNode {
        const index = self.indexOf(mob);
        return self.paths[index * path_capacity ..][0..path_capacity];
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
        @memset(self.damage_flags, .{});
        const registry = self.deps.client.client.get("minecraft:damage_type") orelse return;
        const Tag = struct { name: []const u8, flag: []const u8 };
        const read = [_]Tag{
            .{ .name = "minecraft:is_fire", .flag = "fire" },
            .{ .name = "minecraft:bypasses_cooldown", .flag = "bypasses_cooldown" },
            .{ .name = "minecraft:no_impact", .flag = "no_impact" },
            .{ .name = "minecraft:no_knockback", .flag = "no_knockback" },
            .{ .name = "minecraft:panic_causes", .flag = "panic" },
            .{ .name = "minecraft:bypasses_invulnerability", .flag = "bypasses_invulnerability" },
        };
        inline for (read) |tag| {
            if (registry.tags.find(tag.name)) |found| {
                inline for (@typeInfo(mob_state.DamageType).@"enum".field_names, 0..) |field, index| {
                    if (registry.id("minecraft:" ++ field)) |type_id| {
                        if (registry.tags.contains(found, type_id)) @field(self.damage_flags[index], tag.flag) = true;
                    }
                }
            }
        }
        inline for (@typeInfo(mob_state.DamageType).@"enum".field_names, 0..) |field, index| {
            self.damage_ids[index] = if (registry.id("minecraft:" ++ field)) |type_id| @intCast(type_id) else 0;
        }
    }

    pub fn damageFlags(self: *const Mobs, damage_type: mob_state.DamageType) damage.Flags {
        return self.damage_flags[@backingInt(damage_type)];
    }

    /// The damage type's id in the registry players were sent.
    pub fn damageTypeId(self: *const Mobs, damage_type: mob_state.DamageType) i32 {
        return self.damage_ids[@backingInt(damage_type)];
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
    pub fn shouldPanic(self: *Mobs, mob: *Mob) bool {
        if (self.gameTime() - mob.last_damage_stamp > 40) mob.last_damage = null;
        const dealt = mob.last_damage orelse return false;
        return self.damage_flags[@backingInt(dealt.type)].panic;
    }

    /// Animal.getWalkTargetValue: grass underfoot is best, else the light, through
    /// LevelReader.getPathfindingCostFromLightLevels.
    pub fn walkTargetValue(self: *Mobs, mob: *const Mob, position: [3]i32) !f32 {
        const reader = self.level(mob.world);
        if (reader.blocks.get(try reader.state(position[0], position[1] - 1, position[2])).kind == .grass_block) return 10.0;
        const brightness: f32 = @floatFromInt(try self.rawBrightness(mob.world, position));
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
    pub fn breed(self: *Mobs, mob: *Mob, partner: *Mob) !void {
        if (!self.canSpawn()) return;
        const variant = if (mob.random.nextBoolean()) mob.variant else partner.variant;
        const child = try self.spawnChild(mob, variant);
        _ = child;
        // Animal.finalizeSpawnChildFromBreeding.
        self.setAge(mob, 6000);
        self.setAge(partner, 6000);
        mob.in_love = 0;
        partner.in_love = 0;
        self.entityEvent(mob, 18);
        // One orb of one to seven, from the mob's own random, when mobs drop loot.
        const value = mob.random.nextIntBounded(7) + 1;
        if (self.deps.experience.free_count > 0) try self.deps.experience.spawnOrb(mob.world, mob.position, value);
    }

    fn spawnChild(self: *Mobs, parent: *Mob, variant: u8) !u64 {
        // EntityType.create for breeding, then setBaby and snapTo the parent with no rotation.
        return self.spawn(.{ .species = parent.species, .world = parent.world, .position = parent.position, .yaw = 0, .baby = true, .variant = variant, .finalize = false });
    }

    // What moving and living cause.

    pub fn playSound(self: *Mobs, mob: *const Mob, sound: Sound, volume: f32, pitch: f32) void {
        if (self.muted) return;
        const at: minecraft.Position = .{ .x = mob.position[0], .y = mob.position[1], .z = mob.position[2] };
        self.effects.sound(mob.world, at, sound.name(), .neutral, volume, pitch, @bitCast(self.sound_seeds.next()), null);
    }

    pub fn blockSound(self: *Mobs, world: u32, at: [3]f64, sound: Sound, volume: f32, pitch: f32) void {
        self.effects.sound(world, .{ .x = at[0], .y = at[1], .z = at[2] }, sound.name(), .blocks, volume, pitch, @bitCast(self.sound_seeds.next()), null);
    }

    /// Mob.playStepSound as each species overrides it.
    pub fn stepSound(self: *Mobs, mob: *const Mob, _: u16) void {
        switch (mob.species) {
            .cow => self.playSound(mob, .cow_step, 0.15, 1.0),
        }
    }

    /// The block's fall sound at half volume and three quarters pitch. Block sound types are not
    /// in the snapshot yet, so this plays the generic fall sound.
    pub fn blockFallSound(self: *Mobs, mob: *const Mob, _: u16) void {
        self.playSound(mob, .generic_small_fall, 0.5, 0.75);
    }

    /// ServerLevel.sendParticles of block particles. Particle packets are not written yet.
    pub fn blockParticles(_: *Mobs, _: u32, _: [3]f64, _: u16, _: i32, _: f32) void {}

    pub fn hurt(self: *Mobs, mob: *Mob, dealt: mob_state.Damage, amount: f32) !bool {
        return damage.hurt(self, mob, dealt, amount);
    }

    /// ServerLevel.broadcastDamageEvent, for the replication to send.
    pub fn damageEvent(_: *Mobs, mob: *Mob, dealt: mob_state.Damage) void {
        if (mob.damage_event_count == mob.damage_events.len) {
            mob.damage_events[0] = mob.damage_events[1];
            mob.damage_event_count -= 1;
        }
        mob.damage_events[mob.damage_event_count] = dealt;
        mob.damage_event_count += 1;
    }

    /// LivingEntity.knockback. A direction too short to normalize turns random, from Math.random
    /// rather than the mob's random.
    pub fn knockback(self: *Mobs, mob: *Mob, strength_in: f64, x_in: f64, z_in: f64) void {
        const strength = strength_in * (1.0 - self.traits(mob.species).attribute(.knockback_resistance));
        if (strength <= 0) return;
        mob.has_impulse = true;
        var x = x_in;
        var z = z_in;
        const random = self.seeds.random();
        while (x * x + z * z < @as(f64, @as(f32, 1.0e-5))) {
            x = (random.float(f64) - random.float(f64)) * 0.01;
            z = (random.float(f64) - random.float(f64)) * 0.01;
        }
        const direction = living.normalize(.{ x, 0, z });
        const velocity = mob.velocity;
        mob.velocity = .{
            velocity[0] / 2.0 - direction[0] * strength,
            if (mob.on_ground) @min(0.4, velocity[1] / 2.0 + strength) else velocity[1],
            velocity[2] / 2.0 - direction[2] * strength,
        };
    }

    /// LivingEntity.makeSound: at the mob's volume and voice pitch.
    pub fn makeSound(self: *Mobs, mob: *Mob, sound: Sound) void {
        const volume = self.traits(mob.species).sound_volume;
        const pitch = self.voicePitch(mob);
        self.playSound(mob, sound, volume, pitch);
    }

    /// Animal.setInLove: ten seconds of hearts.
    pub fn setInLove(self: *Mobs, mob: *Mob, cause: ?u128) void {
        mob.in_love = 600;
        mob.love_cause = cause;
        self.entityEvent(mob, 18);
    }

    /// AgeableMob.ageUp: a baby grows by seconds, and the growth fed to it is remembered.
    pub fn ageUp(self: *Mobs, mob: *Mob, seconds: i32, forced: bool) void {
        const before = mob.age;
        var age = before + seconds * 20;
        if (age > 0) age = 0;
        const grown = age - before;
        self.setAge(mob, age);
        if (forced) {
            mob.forced_age += grown;
            if (mob.forced_age_timer == 0) mob.forced_age_timer = 40;
        }
        if (mob.age == 0) self.setAge(mob, mob.forced_age);
    }

    /// ExperienceOrb.award at the mob, as LivingEntity.dropExperience does.
    pub fn awardExperience(self: *Mobs, mob: *const Mob, amount: i32) !void {
        if (!self.deps.experience.canAward(amount)) return;
        try self.deps.experience.award(mob.world, mob.position, amount);
    }

    /// LivingEntity.dropFromLootTable: the species' table, knowing whether the mob burned, who
    /// killed it and with what, dropped where it died as Entity.spawnAtLocation drops items.
    pub fn dropLoot(self: *Mobs, mob: *Mob, dealt: mob_state.Damage, by_player: bool) !void {
        const name = switch (mob.species) {
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
            .location = .{ .world = mob.world, .x = mob.position[0], .y = mob.position[1], .z = mob.position[2] },
            .on_fire = mob.fire_ticks > 0,
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
        if (drops.len == 0 or !self.deps.dropped.canCreate(drops.len)) return;
        var requests: [loot.maximum_drops]ItemEntities.Spawn = undefined;
        var spawned: [loot.maximum_drops]entities.Id = undefined;
        for (drops, requests[0..drops.len]) |drop, *request| {
            const dx = self.level_random.nextDouble() * 0.2 - 0.1;
            const dz = self.level_random.nextDouble() * 0.2 - 0.1;
            request.* = .{
                .world = mob.world,
                .position = mob.position,
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
    pub fn entityEvent(_: *Mobs, mob: *Mob, event: u8) void {
        if (mob.event_count == mob.events.len) {
            std.mem.copyForwards(u8, mob.events[0 .. mob.events.len - 1], mob.events[1..]);
            mob.event_count -= 1;
        }
        mob.events[mob.event_count] = event;
        mob.event_count += 1;
    }

    /// LivingEntity.tickDeath: the body lies twenty ticks, then goes in a puff.
    pub fn tickDeath(self: *Mobs, mob: *Mob) void {
        mob.death_time += 1;
        if (mob.death_time >= 20 and !mob.removed) {
            self.entityEvent(mob, 60);
            mob.removed = true;
        }
    }

    /// LivingEntity.getVoicePitch.
    pub fn voicePitch(_: *Mobs, mob: *Mob) f32 {
        const spread = (mob.random.nextFloat() - mob.random.nextFloat()) * 0.2;
        return spread + (if (mob.baby()) @as(f32, 1.5) else 1.0);
    }

    /// Mob.playAmbientSound.
    pub fn ambientSound(self: *Mobs, mob: *Mob) void {
        const volume = self.traits(mob.species).sound_volume;
        const pitch = self.voicePitch(mob);
        switch (mob.species) {
            .cow => self.playSound(mob, .cow_ambient, volume, pitch),
        }
    }

    /// AgeableMob.setAge: growing up or becoming a baby changes the size viewers see.
    pub fn setAge(self: *Mobs, mob: *Mob, age: i32) void {
        const was_baby = mob.age < 0;
        mob.age = age;
        if (was_baby == (age < 0)) return;
        mob.revision +%= 1;
        // A new size reaches new blocks and mobs, and others find it by its new box at once.
        const grown = living.box(self, mob);
        self.wake(mob.world, grown.min, grown.max);
        if (self.stored(mob)) self.locate(@intCast(self.indexOf(mob)));
    }

    /// Whether a mob is one the plugin holds, and not a copy Debug checks run on.
    fn stored(self: *const Mobs, mob: *const Mob) bool {
        const address = @intFromPtr(mob);
        return address >= @intFromPtr(self.mobs.ptr) and address < @intFromPtr(self.mobs.ptr + self.mobs.len);
    }

    /// Wakes the resting mobs within reach of a region, which then tick in full. A resting mob
    /// reads blocks up to two outside its box, and touches mobs inside it.
    pub fn wake(self: *Mobs, world: u32, low: [3]f64, high: [3]f64) void {
        const margin = 2.0;
        const reach: body.Box = .{ .min = .{ low[0] - margin, low[1] - margin, low[2] - margin }, .max = .{ high[0] + margin, high[1] + margin, high[2] + margin } };
        var candidates = self.grid.query(world, .{ reach.min[0] - self.widest_half, reach.min[2] - self.widest_half }, .{ reach.max[0] + self.widest_half, reach.max[2] + self.widest_half });
        while (candidates.next()) |index| {
            const mob = &self.mobs[index];
            if (mob.resting and living.box(self, mob).intersects(reach)) self.rouse(index);
        }
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

    /// LivingEntity.pushEntities: mobs push the pushable mobs their box overlaps, in the order vanilla
    /// finds them, and each moves apart, after the cramming check. How many it touched, each of
    /// which wakes, as resting mobs skip their own query.
    pub fn pushEntities(self: *Mobs, mob: *Mob) !u32 {
        const own = living.box(self, mob);
        const found = try self.near(mob, own, .pushable);
        if (found.len == 0) return 0;
        // The maxEntityCramming rule at its default: past 23 others, one tick in four hurts.
        const cramming = 24;
        if (found.len > cramming - 1 and mob.random.nextIntBounded(4) == 0) {
            // None of them rides anything here.
            _ = try self.hurt(mob, .{ .type = .cramming }, 6.0);
        }
        for (found) |index| {
            self.rouse(index);
            push(&self.mobs[index], mob);
        }
        return @intCast(found.len);
    }

    pub const Nearness = enum { pushable, same_species };

    /// The other mobs whose boxes meet a box, in the order EntitySectionStorage.getEntities finds
    /// them: by section, then by when each came into its section. LivingEntity.isPushable keeps
    /// the living off climbables, and asking marks a climber as vanilla's check does. The slice
    /// lasts until the next query.
    pub fn near(self: *Mobs, mob: *const Mob, query: body.Box, which: Nearness) ![]const u32 {
        var count: usize = 0;
        var candidates = self.grid.query(mob.world, .{ query.min[0] - self.widest_half, query.min[2] - self.widest_half }, .{ query.max[0] + self.widest_half, query.max[2] + self.widest_half });
        while (candidates.next()) |index| {
            if (!self.grid.boxes[index].intersects(query)) continue;
            const other = &self.mobs[index];
            if (other.id == mob.id or other.removed) continue;
            switch (which) {
                .pushable => if (!other.alive() or try living.onClimbable(self, other)) continue,
                .same_species => if (other.species != mob.species) continue,
            }
            self.nearby[count] = index;
            count += 1;
        }
        const found = self.nearby[0..count];
        std.mem.sort(u32, found, self, inVanillaOrder);
        return found;
    }

    fn inVanillaOrder(self: *const Mobs, a: u32, b: u32) bool {
        return grid_state.Arrival.before(self.arrivals[a], self.arrivals[b]);
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
        if (eggs.len != 1 or eggs[0] <= '1') return self.destroyBlock(world, position);
        const fewer = withProperty(state, "eggs", &.{eggs[0] - 1}) orelse return;
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, fewer);
        self.effects.worldEvent(world, .{ .x = position[0], .y = position[1], .z = position[2] }, 2001, state);
    }

    /// Level.destroyBlock with no drops: the block's break effect, then air.
    pub fn destroyBlock(self: *Mobs, world: u32, position: [3]i32) !void {
        const level_view = self.level(world);
        const state = try level_view.state(position[0], position[1], position[2]);
        if (game_data.physics.get(state).air) return;
        self.effects.worldEvent(world, .{ .x = position[0], .y = position[1], .z = position[2] }, 2001, state);
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, self.air_state);
    }

    /// LayeredCauldronBlock.handleEntityOnFireInside: a burning mob takes a level of water, and
    /// powder snow turns to water a level lower.
    pub fn lowerCauldron(self: *Mobs, world: u32, position: [3]i32) !void {
        const level_view = self.level(world);
        const state = try level_view.state(position[0], position[1], position[2]);
        const entry = level_view.blocks.get(state);
        if (entry.flags.level == 0) return;
        const remaining = entry.flags.level - 1;
        const lowered: u16 = if (remaining == 0) @intCast(game_data.registry.blockStateId("minecraft:cauldron").?) else blk: {
            const water = game_data.registry.blockStateId(if (remaining == 1) "minecraft:water_cauldron[level=1]" else "minecraft:water_cauldron[level=2]").?;
            break :blk @intCast(water);
        };
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, lowered);
    }

    // Saving.

    const encoded_size = 160;

    fn encode(mob: *const Mob) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = @splat(0);
        var writer = std.Io.Writer.fixed(&bytes);
        writer.writeByte(1) catch unreachable;
        writer.writeByte(@backingInt(mob.species)) catch unreachable;
        writer.writeInt(u128, mob.uuid, .little) catch unreachable;
        writer.writeInt(u32, mob.world, .little) catch unreachable;
        for (mob.position ++ mob.velocity) |value| writer.writeInt(u64, @bitCast(value), .little) catch unreachable;
        writer.writeInt(u32, @bitCast(mob.yaw), .little) catch unreachable;
        writer.writeInt(u32, @bitCast(mob.pitch), .little) catch unreachable;
        writer.writeInt(u64, @bitCast(mob.fall_distance), .little) catch unreachable;
        writer.writeInt(i16, @intCast(std.math.clamp(mob.fire_ticks, std.math.minInt(i16), std.math.maxInt(i16))), .little) catch unreachable;
        writer.writeInt(i16, @intCast(std.math.clamp(mob.air_supply, std.math.minInt(i16), std.math.maxInt(i16))), .little) catch unreachable;
        writer.writeByte(@intFromBool(mob.on_ground)) catch unreachable;
        writer.writeInt(u32, @bitCast(mob.health), .little) catch unreachable;
        writer.writeInt(i16, @intCast(mob.hurt_time), .little) catch unreachable;
        writer.writeInt(i16, @intCast(mob.death_time), .little) catch unreachable;
        writer.writeInt(i32, mob.age, .little) catch unreachable;
        writer.writeInt(i32, mob.forced_age, .little) catch unreachable;
        writer.writeInt(i32, mob.in_love, .little) catch unreachable;
        writer.writeInt(u128, mob.love_cause orelse 0, .little) catch unreachable;
        writer.writeByte(@as(u8, @intFromBool(mob.love_cause != null)) | @as(u8, @intFromBool(mob.persistence_required)) << 1 | @as(u8, @intFromBool(mob.left_handed)) << 2 | @as(u8, @intFromBool(mob.no_ai)) << 3) catch unreachable;
        writer.writeInt(u64, @bitCast(mob.follow_range_bonus), .little) catch unreachable;
        writer.writeByte(mob.variant) catch unreachable;
        writer.writeInt(u64, mob.random.state(), .little) catch unreachable;
        return bytes;
    }

    fn decode(entity: u64, bytes: []const u8) !Mob {
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
            .id = entity,
            .uuid = uuid,
            .species = species,
            .world = world,
            .position = position,
            .old_position = position,
            .velocity = vectors[3..6].*,
            .yaw = yaw,
            .pitch = pitch,
            .old_yaw = yaw,
            .old_pitch = pitch,
            .head_yaw = yaw,
            .body_yaw = yaw,
            .random = .restore(random_state),
            .fall_distance = fall_distance,
            .fire_ticks = fire_ticks,
            .air_supply = air_supply,
            .on_ground = on_ground != 0,
            .health = health,
            .hurt_time = hurt_time,
            .death_time = death_time,
            .age = age,
            .forced_age = forced_age,
            .in_love = in_love,
            .love_cause = if (flags & 1 != 0) love_cause else null,
            .persistence_required = flags & 2 != 0,
            .left_handed = flags & 4 != 0,
            .no_ai = flags & 8 != 0,
            .follow_range_bonus = follow_range_bonus,
            .variant = variant,
        };
    }

    fn keyFor(entity: u64) [9]u8 {
        var key: [9]u8 = undefined;
        key[0] = 1;
        std.mem.writeInt(u64, key[1..9], entity, .big);
        return key;
    }

    fn load(self: *Mobs) !void {
        var after: [9]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        var keys: [16][9]u8 = undefined;
        var values: [16][encoded_size]u8 = undefined;
        var entries: [16]records.ScanEntry = undefined;
        for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
        while (true) {
            const batch = try self.table.scan(&cursor, &entries);
            for (entries[0..batch.count]) |entry| {
                if (entry.key_len != 9 or entry.key[0] != 1) return error.CorruptMob;
                const entity = std.mem.readInt(u64, entry.key[1..9], .big);
                const restored = try decode(entity, entry.value[0..entry.value_len]);
                if (self.deps.worlds.get(restored.world) == null or self.ids.contains(entity) or entity > std.math.maxInt(i32)) return error.CorruptMob;
                if (self.free_count == 0) return error.MobCapacity;
                _ = try self.insert(restored);
                self.saved[self.saved_count] = entity;
                self.saved_count += 1;
            }
            if (!batch.more) break;
        }
        separateUuids(self.mobs, self.nearby[0..self.active.values().len], self.active.values(), self.config.seed);
    }

    /// Mobs saved before UUIDs came from entity ids may share one, as each start drew the same
    /// first UUIDs, and clients show only the first mob with a UUID. Every other mob holding a
    /// UUID already taken draws its own, by UUID order in the neighbour scratch, unused until the
    /// first tick.
    fn separateUuids(mobs: []Mob, order: []u32, active: []const usize, seed: u64) void {
        for (order, active) |*slot, index| slot.* = @intCast(index);
        std.mem.sort(u32, order, @as([]const Mob, mobs), struct {
            fn less(all: []const Mob, a: u32, b: u32) bool {
                if (all[a].uuid != all[b].uuid) return all[a].uuid < all[b].uuid;
                return all[a].id < all[b].id;
            }
        }.less);
        if (order.len == 0) return;
        var last = mobs[order[0]].uuid;
        for (order[1..]) |index| {
            const mob = &mobs[index];
            if (mob.uuid != last) {
                last = mob.uuid;
                continue;
            }
            var random = entityRandom(seed, mob.id);
            mob.uuid = randomUuid(&random);
        }
    }

    pub fn checkpoint(self: *Mobs, space: storage.Space) !void {
        errdefer space.fail();
        var keys: [records.Table.write_batch_size][9]u8 = undefined;
        var values: [records.Table.write_batch_size][encoded_size]u8 = undefined;
        var writes: [records.Table.write_batch_size]records.Write = undefined;
        var count: usize = 0;
        for (self.saved[0..self.saved_count]) |entity| {
            if (self.ids.get(entity)) |index| if (!self.mobs[index].removed) continue;
            keys[count] = keyFor(entity);
            writes[count] = .{ .key = &keys[count], .value = null };
            count += 1;
            if (count == writes.len) {
                try self.table.putBatch(writes[0..count]);
                count = 0;
            }
        }
        self.saved_count = 0;
        for (self.active.values()) |index| {
            const mob = &self.mobs[index];
            if (mob.removed) continue;
            keys[count] = keyFor(mob.id);
            // An idle mob's hot fields are in the herd.
            var current = mob.*;
            const place = self.herd.place_of[index];
            if (place != herd_state.no_place and self.herd.idling[place]) self.herd.writeBack(place, &current);
            values[count] = encode(&current);
            writes[count] = .{ .key = &keys[count], .value = &values[count] };
            count += 1;
            self.saved[self.saved_count] = mob.id;
            self.saved_count += 1;
            if (count == writes.len) {
                try self.table.putBatch(writes[0..count]);
                count = 0;
            }
        }
        if (count > 0) try self.table.putBatch(writes[0..count]);
    }
};

test "mob records round trip" {
    var random = JavaRandom.init(7);
    const original: Mob = .{
        .id = 5,
        .uuid = 0x1234,
        .species = .cow,
        .world = 1,
        .position = .{ 1.5, 64, -3.25 },
        .old_position = .{ 1.5, 64, -3.25 },
        .velocity = .{ 0, -0.0784, 0 },
        .yaw = 90,
        .random = random,
        .health = 7.5,
        .age = -100,
        .in_love = 30,
        .love_cause = 99,
        .variant = 2,
    };
    _ = random.nextInt();
    const decoded = try Mobs.decode(5, &Mobs.encode(&original));
    try std.testing.expectEqual(original.position, decoded.position);
    try std.testing.expectEqual(original.health, decoded.health);
    try std.testing.expectEqual(original.love_cause, decoded.love_cause);
    try std.testing.expectEqual(original.random.state(), decoded.random.state());
}

test "mobs draw UUIDs of their own across restarts, and saved mobs sharing one are told apart" {
    // Each start used to draw the same first UUIDs from a fixed seed; ids never repeat.
    var seen: [256]u128 = undefined;
    for (&seen, 0..) |*uuid, entity| {
        var random = Mobs.entityRandom(0x6d6f6273, 12000 + entity);
        uuid.* = Mobs.randomUuid(&random);
    }
    std.mem.sort(u128, &seen, {}, std.sort.asc(u128));
    for (seen[1..], seen[0 .. seen.len - 1]) |uuid, previous| try std.testing.expect(uuid != previous);

    const shared: u128 = 0x4b41e369_565a_4963_88e5_f3d9fc4a498a;
    const template: Mob = .{ .id = 0, .uuid = shared, .species = .cow, .world = 0, .position = .{ 0, 64, 0 }, .old_position = .{ 0, 64, 0 }, .random = JavaRandom.init(1), .health = 10 };
    var mobs: [4]Mob = .{ template, template, template, template };
    for (&mobs, [_]u64{ 13212, 12124, 13887, 12875 }) |*mob, id| mob.id = id;
    mobs[3].uuid = 7;
    var order: [4]u32 = undefined;
    Mobs.separateUuids(&mobs, &order, &.{ 0, 1, 2, 3 }, 0x6d6f6273);
    // The first saved keeps its UUID, as clients showed it.
    try std.testing.expectEqual(shared, mobs[1].uuid);
    try std.testing.expectEqual(@as(u128, 7), mobs[3].uuid);
    for (mobs, 0..) |mob, at| for (mobs[at + 1 ..]) |other| try std.testing.expect(mob.uuid != other.uuid);
}

fn mth_floor(value: f64) i32 {
    return @intFromFloat(@floor(value));
}

/// Entity.push(Entity): the pusher and the pushed move apart, each by up to 0.05 a tick.
fn push(pushed: *Mob, pusher: *Mob) void {
    var dx = pusher.position[0] - pushed.position[0];
    var dz = pusher.position[2] - pushed.position[2];
    var farthest = @max(@abs(dx), @abs(dz));
    if (farthest < @as(f64, @as(f32, 0.01))) return;
    farthest = @sqrt(farthest);
    dx /= farthest;
    dz /= farthest;
    const scale = @min(1.0, 1.0 / farthest);
    dx *= scale * @as(f64, @as(f32, 0.05));
    dz *= scale * @as(f64, @as(f32, 0.05));
    pushed.velocity[0] -= dx;
    pushed.velocity[2] -= dz;
    pushed.has_impulse = true;
    pusher.velocity[0] += dx;
    pusher.velocity[2] += dz;
    pusher.has_impulse = true;
}

const ColumnTicks = struct { revision: u64 = std.math.maxInt(u64), world: u32 = 0, chunk: [2]i32 = .{ 0, 0 }, ticks: bool = false };

const WorldView = struct { world: u32, level: body.Level, ultrawarm: bool };

/// The entity section a position is in, as SectionPos.of(blockPosition).
fn sectionOf(position: [3]f64) [3]i32 {
    return .{ @divFloor(mth_floor(position[0]), 16), @divFloor(mth_floor(position[1]), 16), @divFloor(mth_floor(position[2]), 16) };
}

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
