//! The mobs of every world, in a fixed array with a spatial index, ticked in vanilla's order
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
const spatial = @import("vanilla_item_entities").item_spatial;
const world_effects = @import("vanilla_blocks").world_effects;
const body = @import("body.zig");
const living = @import("living.zig");
const mth = @import("mth.zig");
const content_tags = @import("vanilla_content").content_tags;
const mob_tick = @import("mob_tick.zig");
const mob_blocks = @import("mob_blocks.zig");
const species_data = @import("species.zig");
const mob_state = @import("mob.zig");
const JavaRandom = @import("java_random.zig").JavaRandom;
const pathfinding = @import("pathfinding.zig");
const goals = @import("goals.zig");
const inventories = @import("inventories");
const Lighting = @import("terrain").lighting.Lighting;
const LightSample = @import("terrain").lighting.Sample;
const Time = @import("vanilla_world").time.Time;
const Weather = @import("vanilla_world").weather.Weather;
const Items = @import("vanilla_items").items.Items;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const Experience = @import("vanilla_survival").experience.Experience;
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
    };

    deps: Dependencies,
    config: Configuration,
    mobs: []Mob,
    residents: []spatial.Resident,
    spatial: spatial.Index,
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
    /// The last path found, until a navigation takes it.
    scratch_path: []pathfinding.PathNode,
    scratch: struct { count: u16 = 0, target: [3]i32 = .{ 0, 0, 0 }, reached: bool = false } = .{},
    /// The cow_food item tag and the panic_causes damage type tag, read when definitions change.
    food_tag: ?content_tags.Tags.Id = null,
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
        const self = try allocator.create(Mobs);
        const residents = try allocator.alloc(spatial.Resident, config.maximum);
        @memset(residents, .{});
        self.* = .{
            .deps = deps,
            .config = config,
            .mobs = try allocator.alloc(Mob, config.maximum),
            .residents = residents,
            .spatial = try .init(allocator, residents),
            .active = try .init(allocator, config.maximum),
            .free = try allocator.alloc(u32, config.maximum),
            .free_count = config.maximum,
            .blocks = try mob_blocks.MobBlocks.init(allocator, deps.block_definitions),
            .copies = try chunks.Copies.init(allocator, deps.chunks, config.copies),
            .species = undefined,
            .level_random = .init(@bitCast(config.seed)),
            .seeds = .init(config.seed ^ 0x73656564),
            .sound_seeds = .init(config.seed ^ 0x736f756e64),
            .effects = try .init(allocator, deps.players),
            .table = records.Table.init(deps.storage, deps.record_workspaces.resources),
            .saved = try allocator.alloc(u64, config.maximum),
            .air_state = @intCast(game_data.registry.blockStateId("minecraft:air").?),
            .search = try .init(allocator, search_nodes),
            .paths = try allocator.alloc(pathfinding.PathNode, config.maximum * path_capacity),
            .scratch_path = try allocator.alloc(pathfinding.PathNode, path_capacity),
            .damage_flags = try allocator.alloc(damage.Flags, @typeInfo(mob_state.DamageType).@"enum".field_names.len),
            .damage_ids = try allocator.alloc(i32, @typeInfo(mob_state.DamageType).@"enum".field_names.len),
        };
        try self.readTags();
        try deps.items.deps.definitions.registry.onChange(self, readTags);
        try deps.client.registry.onChange(self, readTags);
        for (self.free, 0..) |*slot, index| slot.* = @intCast(config.maximum - 1 - index);
        inline for (@typeInfo(Species).@"enum".field_names, 0..) |field, index| self.species[index] = species_data.traits(@field(Species, field));
        try self.ids.ensureTotalCapacity(allocator, @intCast(config.maximum));
        return self;
    }

    pub fn traits(self: *const Mobs, species: Species) *const species_data.Traits {
        return &self.species[@backingInt(species)];
    }

    pub fn level(self: *Mobs, world: u32) body.Level {
        const definition = self.deps.worlds.get(world).?;
        return .{
            .copies = self.copies,
            .blocks = self.blocks,
            .world = world,
            .minimum_y = definition.dimension.minimumSection() * 16,
            .height = @intCast(definition.dimension.sectionCount() * 16),
            .air = self.air_state,
        };
    }

    pub fn ultrawarm(self: *const Mobs, world: u32) bool {
        const definition = self.deps.worlds.get(world) orelse return false;
        const dimension = self.deps.dimensions.get(definition.dimension.name) orelse return false;
        return dimension.ultrawarm;
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
        var random = JavaRandom.init(@bitCast(self.seeds.next()));
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
        self.residents[index] = .{ .id = created.id };
        self.locate(index);
        return created.id;
    }

    /// Keeps the spatial index on the section a mob is in.
    pub fn locate(self: *Mobs, index: u32) void {
        const mob = &self.mobs[index];
        const resident = &self.residents[index];
        const x = @divFloor(mob.blockPosition()[0], 16);
        const y = @divFloor(mob.blockPosition()[1], 16);
        const z = @divFloor(mob.blockPosition()[2], 16);
        const alive = !mob.removed;
        if (resident.alive and resident.world == mob.world and resident.x == x and resident.y == y and resident.z == z) {
            resident.position = .{ mob.position[0], mob.position[2] };
            return;
        }
        if (resident.alive) self.spatial.remove(index);
        resident.* = .{ .id = mob.id, .world = mob.world, .x = x, .y = y, .z = z, .position = .{ mob.position[0], mob.position[2] }, .alive = alive };
        if (alive) self.spatial.insert(index);
    }

    /// Forgets a removed mob. Its viewers have been told, so the slot is free.
    pub fn release(self: *Mobs, index: u32) void {
        const mob = &self.mobs[index];
        assert(mob.removed);
        if (self.residents[index].alive) self.spatial.remove(index);
        self.residents[index].alive = false;
        assert(self.ids.remove(mob.id));
        self.active.remove(index);
        self.free[self.free_count] = index;
        self.free_count += 1;
    }

    pub fn get(self: *Mobs, entity: u64) ?*Mob {
        const index = self.ids.get(entity) orelse return null;
        return &self.mobs[index];
    }

    pub fn tick(self: *Mobs) !void {
        defer self.copies.endTick();
        for (self.active.values()) |index| {
            const mob = &self.mobs[index];
            if (mob.removed) continue;
            const at = mob.blockPosition();
            if (!self.deps.domains.ticks(.{ .world = mob.world, .x = @divFloor(at[0], 16), .z = @divFloor(at[2], 16) })) continue;
            try mob_tick.tick(self, mob);
            self.locate(@intCast(index));
        }
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
    pub fn isFood(self: *Mobs, _: *const Mob, stack: inventories.Stack) !bool {
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
        try self.dropExperience(mob, mob.random.nextIntBounded(7) + 1);
    }

    fn spawnChild(self: *Mobs, parent: *Mob, variant: u8) !u64 {
        // EntityType.create for breeding, then setBaby and snapTo the parent with no rotation.
        return self.spawn(.{ .species = parent.species, .world = parent.world, .position = parent.position, .yaw = 0, .baby = true, .variant = variant, .finalize = false });
    }

    /// An experience orb, as Animal.finalizeSpawnChildFromBreeding adds one. Orbs come with the
    /// survival package's experience, which mobs reach once loot lands.
    fn dropExperience(_: *Mobs, _: *Mob, _: i32) !void {}

    // What moving and living cause.

    pub fn playSound(self: *Mobs, mob: *const Mob, sound: Sound, volume: f32, pitch: f32) void {
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

    /// LivingEntity.dropFromLootTable. Mob loot tables come next.
    pub fn dropLoot(_: *Mobs, _: *Mob, _: mob_state.Damage, _: bool) !void {}

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
    pub fn setAge(_: *Mobs, mob: *Mob, age: i32) void {
        const was_baby = mob.age < 0;
        mob.age = age;
        if (was_baby != (age < 0)) mob.revision +%= 1;
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

    /// LivingEntity.pushEntities: mobs push the mobs their box overlaps, and each moves apart.
    pub fn pushEntities(self: *Mobs, mob: *Mob) !void {
        const own = living.box(self, mob);
        const low: [2]i32 = .{ @divFloor(mth_floor(own.min[0]) - 1, 16), @divFloor(mth_floor(own.min[2]) - 1, 16) };
        const high: [2]i32 = .{ @divFloor(mth_floor(own.max[0]) + 1, 16), @divFloor(mth_floor(own.max[2]) + 1, 16) };
        var candidates = self.spatial.rectangle(mob.world, low, high);
        while (candidates.next()) |index| {
            const other = &self.mobs[index];
            if (other == mob or other.removed or !other.alive()) continue;
            if (!living.box(self, other).intersects(own)) continue;
            push(other, mob);
        }
    }

    /// FarmBlock.turnToDirt.
    pub fn trampleFarmland(self: *Mobs, world: u32, position: [3]i32, _: u16) !void {
        try self.deps.chunks.setBlock(world, .{ .x = position[0], .y = position[1], .z = position[2] }, @intCast(game_data.registry.blockStateId("minecraft:dirt").?));
    }

    /// TurtleEggBlock.decreaseEggs. Turtle eggs keep their count until turtles exist.
    pub fn crackTurtleEgg(_: *Mobs, _: u32, _: [3]i32, _: u16) !void {}

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
            values[count] = encode(mob);
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

/// Nodes one path search may make. A cow visits at most 285 and makes a few per visit.
const search_nodes = 16384;
/// Nodes one path may hold: the most a search can visit, plus its start.
const path_capacity = 320;
