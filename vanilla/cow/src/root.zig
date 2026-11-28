//! The cow, AbstractCow and Cow, as a species of the Mobs plugin: the animal goals at its speeds,
//! its voice, its variant as its own data, and milk from a bucket.

const std = @import("std");
const game_data = @import("game_data");
const mob_state = @import("vanilla_mobs").mob;
const species_data = @import("vanilla_mobs").species;
const Mobs = @import("vanilla_mobs").mobs.Mobs;
const Use = @import("vanilla_mobs").mob_interaction.Use;

const Mob = mob_state.Mob;

pub const Cow = struct {
    pub const id = "minecraft:cow";
    pub const Configuration = struct {};
    pub const Dependencies = struct { mobs: *Mobs };

    deps: Dependencies,
    species: mob_state.Species,
    bucket: u32,
    milk_bucket: u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Cow {
        const self = try allocator.create(Cow);
        self.* = .{
            .deps = deps,
            .species = undefined,
            .bucket = @intCast(game_data.registry.itemId("minecraft:bucket").?),
            .milk_bucket = @intCast(game_data.registry.itemId("minecraft:milk_bucket").?),
        };
        var definition = cow;
        definition.hooks.context = self;
        self.species = try deps.mobs.register(definition);
        return self;
    }

    /// The cow's variant, as the registry numbers it.
    pub fn variant(mob: Mob) u8 {
        return mob.kin.bytes[0];
    }
};

/// CowVariants.TEMPERATE, the variant a cow has unless it spawned elsewhere.
pub const default_variant: u8 = variant: {
    @setEvalBranchQuota(1_000_000);
    for (game_data.registry.named_registries) |named| {
        if (!std.mem.eql(u8, named.name, "minecraft:cow_variant")) continue;
        for (named.entries, 0..) |entry, index| if (std.mem.eql(u8, entry, "minecraft:temperate")) break :variant index;
    }
    unreachable;
};

const cow: species_data.Definition = .{
    .entity = "minecraft:cow",
    // AbstractCow.registerGoals.
    .panic_speed = 2.0,
    .tempt_speed = 1.25,
    .follow_parent_speed = 1.25,
    .food_tag = "minecraft:cow_food",
    .loot_table = "minecraft:entities/cow",
    .sounds = .{ .ambient = "minecraft:entity.cow.ambient", .hurt = "minecraft:entity.cow.hurt", .death = "minecraft:entity.cow.death", .step = "minecraft:entity.cow.step" },
    // AbstractCow.getSoundVolume and BABY_DIMENSIONS.
    .sound_volume = 0.4,
    .baby_eye_height = 0.665,
    // Cow.DATA_VARIANT_ID.
    .data = &.{.{ .key = 17, .modern_key = 18, .serializer = .cow_variant, .kin = 0, .default = default_variant }},
    .idles = true,
    .hooks = .{ .finalize = finalize, .offspring = offspring, .interact = interact },
};

/// Cow.finalizeSpawn: the temperate variant, as the biomes here give, the variant's spawn
/// conditions not yet read.
fn finalize(_: *anyopaque, _: *Mobs, created: *mob_state.MobState) !void {
    created.kin.bytes[0] = default_variant;
}

/// Cow.getBreedOffspring: one parent's variant, by the first's random.
fn offspring(_: *anyopaque, _: *Mobs, parent: Mob, other: Mob, kin: *mob_state.Kin) !void {
    kin.bytes[0] = if (parent.idle.random.nextBoolean()) Cow.variant(parent) else Cow.variant(other);
}

/// AbstractCow.mobInteract: a bucket fills with milk from a grown cow.
fn interact(context: *anyopaque, use: *const Use) !bool {
    const self: *Cow = @ptrCast(@alignCast(context));
    if (use.kind != self.bucket or use.mob.baby()) return false;
    use.interaction.playerSound(use.slot, "minecraft:entity.cow.milk");
    try use.interaction.exchange(use.slot, use.hand, self.milk_bucket);
    return true;
}

comptime {
    // A plugin compiles only where referenced, so its tests reference it.
    _ = &Cow.init;
}
