//! The sheep, Sheep, as a species of the Mobs plugin: the animal goals at its speeds with its
//! EatBlockGoal, its wool as its own data, shorn with shears and dyed with dyes, a colour by its
//! biome as SheepColorSpawnRules weighs them, and a lamb's from its parents' dyes, as
//! DyeColor.getMixedColor asks the crafting recipes.

const std = @import("std");
const game_data = @import("game_data");
const entities = @import("entities");
const recipes = @import("vanilla_crafting").recipes;
const Crafting = @import("vanilla_crafting").crafting_registry.Crafting;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const loot = @import("vanilla_items").loot;
const item_data = @import("vanilla_items").item_data;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const JavaRandom = @import("vanilla_bodies").java_random.JavaRandom;
const mth = @import("vanilla_bodies").mth;
const mob_state = @import("vanilla_mobs").mob;
const species_data = @import("vanilla_mobs").species;
const goals = @import("vanilla_mobs").goals;
const navigation = @import("vanilla_mobs").navigation;
const Mobs = @import("vanilla_mobs").mobs.Mobs;
const Use = @import("vanilla_mobs").mob_interaction.Use;

const Mob = mob_state.Mob;

pub const Sheep = struct {
    pub const id = "minecraft:sheep";
    pub const Configuration = struct {};
    pub const Dependencies = struct { mobs: *Mobs, client: *ClientRegistries, crafting: *Crafting };

    deps: Dependencies,
    species: mob_state.Species,
    /// By biome, the climate SheepColorSpawnRules gives it, and by state, the edible_for_sheep
    /// block tag: read when tags change.
    climates: []Climate,
    edible: []bool,
    eat_block: species_data.OwnGoal,
    shears: u32,
    grass_block: u16,
    dirt: u16,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Sheep {
        const self = try allocator.create(Sheep);
        self.* = .{
            .deps = deps,
            .species = undefined,
            .climates = try allocator.alloc(Climate, game_data.registry.biome_names.len),
            .edible = try allocator.alloc(bool, game_data.registry.block_state_names.len),
            .eat_block = .{ .context = self, .flags = .{ .move = true, .look = true, .jump = true }, .can_use = eatCanUse, .can_continue = eatCanContinue, .start = eatStart, .stop = eatStop, .tick = eatTick },
            .shears = @intCast(game_data.registry.itemId("minecraft:shears").?),
            .grass_block = @intCast(game_data.registry.blockStateId("minecraft:grass_block[snowy=false]").?),
            .dirt = @intCast(game_data.registry.blockStateId("minecraft:dirt").?),
        };
        try self.readTags();
        try deps.client.registry.onChange(self, readTags);
        try deps.mobs.blocks.block_definitions.registry.onChange(self, readTags);
        // Sheep.registerGoals: the animal goals with eating grass before strolling.
        const goal_list = try allocator.create([9]species_data.Goal);
        goal_list.* = .{ .{ .shared = .float }, .{ .shared = .panic }, .{ .shared = .breed }, .{ .shared = .tempt }, .{ .shared = .follow_parent }, .{ .own = &self.eat_block }, .{ .shared = .stroll }, .{ .shared = .look_at_player }, .{ .shared = .look_around } };
        var definition = sheep;
        definition.goals = goal_list;
        definition.hooks.context = self;
        self.species = try deps.mobs.register(definition);
        return self;
    }

    /// SheepColorSpawnRules.getSheepColorConfiguration, warm before cold, and EatBlockGoal's
    /// IS_EDIBLE.
    fn readTags(self: *Sheep) !void {
        @memset(self.climates, .temperate);
        self.deps.mobs.blocks.statesOfTag("minecraft:edible_for_sheep", self.edible);
        const biomes = self.deps.client.client.get("minecraft:worldgen/biome") orelse return;
        for ([_]struct { []const u8, Climate }{ .{ "minecraft:spawns_cold_variant_farm_animals", .cold }, .{ "minecraft:spawns_warm_variant_farm_animals", .warm } }) |entry| {
            const found = biomes.tags.find(entry[0]) orelse continue;
            for (biomes.tags.members(found)) |member| {
                if (member >= biomes.entries.len) continue;
                const biome = game_data.registry.biomeId(biomes.entries[member].name) orelse continue;
                self.climates[@intCast(biome)] = entry[1];
            }
        }
    }

    /// The climate of the biome at a position: temperate where the level keeps no biomes.
    fn climateAt(self: *Sheep, world: u32, position: [3]f64) !Climate {
        const at: [3]i32 = .{ mth.floor(position[0]), mth.floor(position[1]), mth.floor(position[2]) };
        const level = self.deps.mobs.level(world);
        const biome = (try level.biome(at)) orelse return .temperate;
        return if (biome < self.climates.len) self.climates[biome] else .temperate;
    }
};

/// A sheep's wool, its first kin byte as Sheep.DATA_WOOL_ID: the colour in the low four bits,
/// sheared in the fifth. EatBlockGoal.eatAnimationTick is the second, while it eats.
pub const Wool = struct {
    pub const sheared_bit: u8 = 0x10;

    pub fn color(mob: Mob) Color {
        return @fromBackingInt(@intCast(@as(u4, @truncate(mob.kin.bytes[0]))));
    }

    pub fn sheared(mob: Mob) bool {
        return mob.kin.bytes[0] & sheared_bit != 0;
    }

    fn set(mobs: *Mobs, mob: Mob, wool: u8) void {
        if (mob.kin.bytes[0] == wool) return;
        mob.kin.bytes[0] = wool;
        mobs.kinChanged(mob);
    }
};

const sheep: species_data.Definition = .{
    .entity = "minecraft:sheep",
    // Sheep.registerGoals.
    .panic_speed = 1.25,
    .tempt_speed = 1.1,
    .follow_parent_speed = 1.1,
    .food_tag = "minecraft:sheep_food",
    .loot_table = "minecraft:entities/sheep",
    .sounds = .{ .ambient = "minecraft:entity.sheep.ambient", .hurt = "minecraft:entity.sheep.hurt", .death = "minecraft:entity.sheep.death", .step = "minecraft:entity.sheep.step" },
    // Sheep.DATA_WOOL_ID.
    .data = &.{.{ .key = 17, .modern_key = 18, .serializer = .byte, .kin = 0 }},
    .hooks = .{ .finalize = finalize, .offspring = offspring, .ate = ate, .interact = interact, .use_item = useItem, .facts = facts },
};

fn ownSheep(context: *anyopaque) *Sheep {
    return @ptrCast(@alignCast(context));
}

/// Sheep.finalizeSpawn: the colour of its biome, from the level's random, before Mob's draws.
fn finalize(context: *anyopaque, mobs: *Mobs, created: *mob_state.MobState) !void {
    const self = ownSheep(context);
    const climate = try self.climateAt(created.motion.world, created.motion.position);
    created.kin.bytes[0] = @backingInt(spawnColor(climate, mobs.levelRandom()));
}

/// Sheep.getBreedOffspring: the colour its parents' dyes craft.
fn offspring(context: *anyopaque, mobs: *Mobs, parent: Mob, other: Mob, kin: *mob_state.Kin) !void {
    const self = ownSheep(context);
    kin.bytes[0] = @backingInt(mixedColor(&self.deps.crafting.table, Wool.color(parent), Wool.color(other), mobs.levelRandom()));
}

/// Sheep.ate: its wool grows back, and a lamb grows a minute.
fn ate(_: *anyopaque, mobs: *Mobs, mob: Mob) !void {
    Wool.set(mobs, mob, mob.kin.bytes[0] & ~Wool.sheared_bit);
    if (mob.baby()) try mobs.ageUp(mob, 60, false);
}

/// Sheep.mobInteract: shears shear a grown sheep with its wool, and held at any other sheep do
/// nothing more.
fn interact(context: *anyopaque, use: *const Use) !bool {
    const self = ownSheep(context);
    if (use.kind != self.shears) return false;
    const mob = use.mob;
    if (!mob.alive() or Wool.sheared(mob) or mob.baby()) return true;
    const mobs = self.deps.mobs;
    const tool = try mobs.deps.items.acquire(use.held);
    defer tool.release();
    try shear(mobs, mob, tool.view);
    try use.interaction.wearHeld(use.slot, use.hand);
    return true;
}

/// Sheep.shear: the shearing sound for everyone near, its shearing loot dropped a wool at a time
/// a block above its feet, each tossed further by its own random, and it is sheared.
fn shear(mobs: *Mobs, mob: Mob, tool: item_data.View) !void {
    const at = mob.motion.position;
    mobs.effects.sound(mob.motion.world, .{ .x = at[0], .y = at[1], .z = at[2] }, "minecraft:entity.sheep.shear", .players, 1.0, 1.0, @bitCast(mobs.sound_seeds.next()), null);
    if (mobs.deps.loot.tables.get("minecraft:shearing/sheep")) |table| {
        mobs.loot_scratch.reset();
        var buffer: [loot.maximum_drops]loot.Drop = undefined;
        const context: loot.Context = .{
            .items = mobs.deps.items.deps.definitions,
            .location = .{ .world = mob.motion.world, .x = at[0], .y = at[1], .z = at[2] },
            .tool = tool,
            .entity_facts = facts(mob),
            .random = mobs.loot_random.random(),
            .scratch = &mobs.loot_scratch,
        };
        const drops = table.evaluate(&context, &buffer) catch |err| switch (err) {
            error.OutOfMemory, error.LootCapacity => &.{},
            else => return err,
        };
        var requests: [loot.maximum_drops]ItemEntities.Spawn = undefined;
        var count: usize = 0;
        for (drops) |drop| for (0..drop.count) |_| {
            if (count == requests.len) break;
            // Entity.spawnAtLocation a block up: ItemEntity's own toss from the level's random,
            // then the sheep's.
            const level_random = mobs.levelRandom();
            const dx = level_random.nextDouble() * 0.2 - 0.1;
            const dz = level_random.nextDouble() * 0.2 - 0.1;
            const random = &mob.idle.random;
            const tx: f64 = (random.nextFloat() - random.nextFloat()) * 0.1;
            const ty: f64 = random.nextFloat() * 0.05;
            const tz: f64 = (random.nextFloat() - random.nextFloat()) * 0.1;
            requests[count] = .{
                .world = mob.motion.world,
                .position = .{ at[0], at[1] + 1.0, at[2] },
                .velocity = .{ dx + tx, 0.2 + ty, dz + tz },
                .stack = .{ .item = try item_data.define(mobs.deps.inventories, drop.kind, drop.components), .count = 1 },
            };
            count += 1;
        };
        var spawned: [loot.maximum_drops]entities.Id = undefined;
        try mobs.deps.dropped.createMany(requests[0..count], spawned[0..count]);
    }
    Wool.set(mobs, mob, mob.kin.bytes[0] | Wool.sheared_bit);
}

/// DyeItem.interactLivingEntity: a live sheep with wool of another colour takes the dye's, with
/// the dye's sound.
fn useItem(context: *anyopaque, use: *const Use) !bool {
    const self = ownSheep(context);
    const color = Color.ofDye(use.kind) orelse return false;
    const mob = use.mob;
    if (!mob.alive() or Wool.sheared(mob) or Wool.color(mob) == color) return false;
    use.sound("minecraft:item.dye.use");
    Wool.set(self.deps.mobs, mob, (mob.kin.bytes[0] & 0xf0) | @backingInt(color));
    try use.interaction.usePlayerItem(use.slot, use.hand);
    return true;
}

/// What the sheep's loot tables ask of it: its sheep/color component, and being a sheep, sheared
/// or not.
fn facts(mob: Mob) loot.EntityFacts {
    return woolFacts(mob.kin);
}

/// The same of a sheep's kin alone, good while it is.
pub fn woolFacts(kin: *const mob_state.Kin) loot.EntityFacts {
    return .{ .context = kin, .is = isSheep, .component = component, .field = field };
}

fn isSheep(_: *const anyopaque, entity_type: []const u8) bool {
    return std.mem.eql(u8, entity_type, "minecraft:sheep");
}

fn component(context: *const anyopaque, name: []const u8) ?loot.Fact {
    const kin: *const mob_state.Kin = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, name, "minecraft:sheep/color")) return null;
    return .{ .text = @tagName(@as(Color, @fromBackingInt(@intCast(@as(u4, @truncate(kin.bytes[0])))))) };
}

fn field(context: *const anyopaque, name: []const u8) ?loot.Fact {
    const kin: *const mob_state.Kin = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, name, "sheared")) return null;
    return .{ .boolean = kin.bytes[0] & Wool.sheared_bit != 0 };
}

// EatBlockGoal, the sheep's own, its animation tick the second kin byte.

fn eatCanUse(context: *anyopaque, mobs: *Mobs, mob: Mob) !bool {
    const self = ownSheep(context);
    if (mob.idle.random.nextIntBounded(if (mob.baby()) 50 else 1000) != 0) return false;
    const level = mobs.level(mob.motion.world);
    const at = mob.blockPosition();
    if (self.edible[try level.state(at[0], at[1], at[2])]) return true;
    return isGrassBlock(mobs, try level.state(at[0], at[1] - 1, at[2]));
}

fn eatCanContinue(_: *anyopaque, _: *Mobs, mob: Mob) !bool {
    return mob.kin.bytes[1] > 0;
}

/// EatBlockGoal.start: the eating animation, which viewers see as entity event 10, and a halt.
fn eatStart(_: *anyopaque, mobs: *Mobs, mob: Mob) !void {
    mob.kin.bytes[1] = @intCast(goals.reducedTickDelay(40));
    mobs.entityEvent(mob, 10);
    navigation.stop(mob);
}

fn eatStop(_: *anyopaque, _: *Mobs, mob: Mob) void {
    mob.kin.bytes[1] = 0;
}

/// EatBlockGoal.tick: two goal ticks before the animation ends, the plant it stands in goes, or
/// else the grass block under it turns to dirt, and either way it ate.
fn eatTick(context: *anyopaque, mobs: *Mobs, mob: Mob) !void {
    const self = ownSheep(context);
    const eating = &mob.kin.bytes[1];
    eating.* -|= 1;
    if (eating.* != goals.reducedTickDelay(4)) return;
    const level = mobs.level(mob.motion.world);
    const at = mob.blockPosition();
    if (self.edible[try level.state(at[0], at[1], at[2])]) {
        if (mobs.mobGriefing()) try mobs.deps.block_edits.destroyBlock(mob.motion.world, at);
        try mobs.ate(mob);
        return;
    }
    const below: [3]i32 = .{ at[0], at[1] - 1, at[2] };
    if (!isGrassBlock(mobs, try level.state(below[0], below[1], below[2]))) return;
    if (mobs.mobGriefing()) {
        // Its break effect, then dirt, which tells viewers and no neighbour.
        mobs.effects.worldEvent(mob.motion.world, .{ .x = below[0], .y = below[1], .z = below[2] }, 2001, self.grass_block);
        try mobs.deps.chunks.setBlock(mob.motion.world, .{ .x = below[0], .y = below[1], .z = below[2] }, self.dirt);
    }
    try mobs.ate(mob);
}

/// BlockState.is(Blocks.GRASS_BLOCK), snowy or not.
fn isGrassBlock(mobs: *const Mobs, state: u16) bool {
    return mobs.blocks.get(state).kind == .grass_block;
}

/// DyeColor, by its id.
pub const Color = enum(u4) {
    white,
    orange,
    magenta,
    light_blue,
    yellow,
    lime,
    pink,
    gray,
    light_gray,
    cyan,
    purple,
    blue,
    brown,
    green,
    red,
    black,

    /// The dye item of the colour, DyeItem.byColor.
    pub fn dye(self: Color) u32 {
        return dyes[@backingInt(self)];
    }

    /// The colour a dye item gives, if it is one.
    pub fn ofDye(item: u32) ?Color {
        for (dyes, 0..) |kind, index| if (kind == item) return @fromBackingInt(@intCast(index));
        return null;
    }
};

const dyes: [16]u32 = names: {
    @setEvalBranchQuota(1_000_000);
    var result: [16]u32 = undefined;
    for (@typeInfo(Color).@"enum".field_names, 0..) |name, index| result[index] = @intCast(game_data.registry.itemId("minecraft:" ++ name ++ "_dye").?);
    break :names result;
};

/// Which of SheepColorSpawnRules' configurations a biome takes: warm or cold by its farm animal
/// variant tags, temperate otherwise.
pub const Climate = enum { temperate, warm, cold };

/// SheepColorSpawnRules.getSheepColor: one weighted draw, and for the common colour a second
/// that makes one in five hundred pink.
pub fn spawnColor(climate: Climate, random: *JavaRandom) Color {
    const Weighted = struct { color: Color, weight: i32, common: bool = false };
    const table: []const Weighted = switch (climate) {
        .temperate => &.{ .{ .color = .black, .weight = 5 }, .{ .color = .gray, .weight = 5 }, .{ .color = .light_gray, .weight = 5 }, .{ .color = .brown, .weight = 3 }, .{ .color = .white, .weight = 82, .common = true } },
        .warm => &.{ .{ .color = .gray, .weight = 5 }, .{ .color = .light_gray, .weight = 5 }, .{ .color = .white, .weight = 5 }, .{ .color = .black, .weight = 3 }, .{ .color = .brown, .weight = 82, .common = true } },
        .cold => &.{ .{ .color = .light_gray, .weight = 5 }, .{ .color = .gray, .weight = 5 }, .{ .color = .white, .weight = 5 }, .{ .color = .brown, .weight = 3 }, .{ .color = .black, .weight = 82, .common = true } },
    };
    // WeightedList.getRandomOrThrow: one draw below the total, taken by the entries in order.
    var roll = random.nextIntBounded(100);
    for (table) |entry| {
        if (roll < entry.weight) {
            if (!entry.common) return entry.color;
            // SheepColorSpawnRules.commonColors: the colour weighs 499, pink 1.
            return if (random.nextIntBounded(500) < 499) entry.color else .pink;
        }
        roll -= entry.weight;
    }
    unreachable;
}

/// DyeColor.getMixedColor: what crafting the two dyes side by side makes, if it is a dye, else
/// one of the two, by the level's random.
pub fn mixedColor(table: *const recipes.CraftingTable, first: Color, second: Color, level_random: *JavaRandom) Color {
    const grid = [4]?u32{ first.dye(), second.dye(), null, null };
    if (table.matches(&grid, 2)) |craft| if (Color.ofDye(craft.output)) |mixed| return mixed;
    return if (level_random.nextBoolean()) first else second;
}

test "temperate sheep are mostly white, sometimes pink, as vanilla draws them" {
    var random = JavaRandom.init(42);
    var counts: [16]u32 = @splat(0);
    for (0..100_000) |_| counts[@backingInt(spawnColor(.temperate, &random))] += 1;
    // 82 in 100 common, of which 1 in 500 pink: about 81 836 white and 164 pink.
    try std.testing.expect(counts[@backingInt(Color.white)] > 81_000 and counts[@backingInt(Color.white)] < 82_700);
    try std.testing.expect(counts[@backingInt(Color.pink)] > 80 and counts[@backingInt(Color.pink)] < 260);
    try std.testing.expect(counts[@backingInt(Color.brown)] > 2_700 and counts[@backingInt(Color.brown)] < 3_300);
    try std.testing.expectEqual(@as(u32, 0), counts[@backingInt(Color.red)]);
}

test "dye items name their colours" {
    try std.testing.expectEqual(@as(?Color, .light_blue), Color.ofDye(Color.light_blue.dye()));
    try std.testing.expectEqual(@as(?Color, null), Color.ofDye(@intCast(game_data.registry.itemId("minecraft:wheat").?)));
}

comptime {
    // A plugin compiles only where referenced, so its tests reference it.
    _ = &Sheep.init;
}
