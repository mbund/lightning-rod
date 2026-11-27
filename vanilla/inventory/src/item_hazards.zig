//! What hurts and holds back dropped items, as vanilla's Entity and ItemEntity do: burning and
//! its countdown, the damage blocks deal, and the block effects every body shares, with a
//! dropped item as their subject. Items resist the damage their damage_resistant component
//! names, their stack's own or their kind's.

const std = @import("std");
const game_data = @import("game_data");
const entities = @import("entities");
const inventories = @import("inventories");
const encoding = game_data.encoding;
const bodies = @import("vanilla_bodies");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const Levels = bodies.levels.Levels;
const BlockEdits = bodies.block_edits.BlockEdits;
const Items = @import("vanilla_items").items.Items;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const Blocks = @import("vanilla_content").blocks.Blocks;
const Players = @import("players").players.Players;
const world_effects = @import("vanilla_world").world_effects;
const worlds = @import("worlds");

const effects = bodies.block_effects;
const JavaRandom = bodies.java_random.JavaRandom;
const assert = std.debug.assert;

/// The damage that reaches items, by what vanilla names it.
pub const Damage = enum { cactus, in_fire, campfire, sweet_berry_bush, lava, hot_floor, on_fire };

/// A dropped item through its tick: its body and what of its metadata hazards change.
pub const Subject = struct {
    world: u32,
    position: [3]f64,
    old_position: [3]f64,
    velocity: [3]f64,
    on_ground: bool,
    fall_distance: f64 = 0,
    stuck: [3]f64 = .{ 0, 0, 0 },
    fire_ticks: i32,
    ticks_frozen: i32,
    in_powder_snow: bool = false,
    removed: bool = false,
    health: i16,
    /// Where its stack is, read when first needed.
    slot: inventories.Slot,
    stack: ?inventories.Stack = null,
    /// Whether it resists fire, found when first asked.
    fire_immune: ?bool = null,
    /// Hurt this tick, which sends its velocity again as ItemEntity.hurtServer does.
    hurt: bool = false,
};

pub const Hazards = struct {
    deps: Dependencies,
    scratch: effects.Scratch = .{},
    sounds: world_effects.Effects,
    /// Entity.random for the sounds items make, which vanilla seeds anew for each entity.
    random: JavaRandom,
    level_random: JavaRandom,
    sound_seeds: std.Random.DefaultPrng,

    pub const Dependencies = struct {
        blocks: *Blocks,
        items: *Items,
        client: *ClientRegistries,
        players: *Players,
        worlds: *worlds.Worlds,
        inventories: *inventories.Inventories,
        levels: *Levels,
        block_edits: *BlockEdits,
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !Hazards {
        return .{
            .deps = deps,
            .sounds = try .init(allocator, deps.players),
            // Vanilla seeds these anew for each entity and level; any seed draws alike.
            .random = .init(0x6974656d),
            .level_random = .init(0x6c6576656c),
            .sound_seeds = .init(0x736f756e64),
        };
    }

    /// The start of Entity.baseTick for a burning item: it counts down, hurt by its fire once
    /// a second while out of lava, or four at a time when fire cannot hurt it.
    pub fn burn(self: *Hazards, subject: *Subject, in_lava: bool) !void {
        if (subject.fire_ticks <= 0) return;
        if (try self.fireImmune(subject)) {
            subject.fire_ticks -= 4;
            return;
        }
        if (@mod(subject.fire_ticks, 20) == 0 and !in_lava) _ = try self.hurt(subject, .on_fire, 1.0);
        subject.fire_ticks -= 1;
    }

    /// Entity.applyEffectsFromBlocks for an item that moved this tick.
    pub fn apply(self: *Hazards, subject: *Subject, from: [3]f64) !void {
        const movement: effects.Movement = .{ .from = from, .to = subject.position, .axis_independent = true };
        const context: Context = .{ .hazards = self, .subject = subject };
        const level_view = self.level(subject.world);
        const host = hostOf(&context, &level_view);
        _ = try effects.apply(*const Context, &host, subjectOf(subject), &.{movement});
    }

    /// ItemEntity.isFireImmune: a stack that in_fire does not hurt.
    fn fireImmune(self: *Hazards, subject: *Subject) !bool {
        if (subject.fire_immune == null) subject.fire_immune = try self.resists(subject, .in_fire);
        return subject.fire_immune.?;
    }

    /// ItemEntity.hurtServer: whether it hurt. An item gone or resisting the damage is not
    /// hurt, and one with no health left is destroyed.
    pub fn hurt(self: *Hazards, subject: *Subject, damage: Damage, amount: f32) !bool {
        if (subject.removed) return false;
        if (self.inTag(damage, "minecraft:is_fire") and try self.fireImmune(subject)) return false;
        if (try self.resists(subject, damage)) return false;
        subject.hurt = true;
        subject.health = @intFromFloat(@as(f32, @floatFromInt(subject.health)) - amount);
        if (subject.health <= 0) subject.removed = true;
        return true;
    }

    /// ItemStack.takesDamageFrom, inverted: whether the stack's damage_resistant tag, its
    /// own or else its kind's, holds the damage type.
    fn resists(self: *Hazards, subject: *Subject, damage: Damage) !bool {
        if (subject.stack == null) subject.stack = (try self.deps.inventories.get(subject.slot)).stack orelse return error.Corrupt;
        const prepared = try self.deps.items.acquire(subject.stack.?);
        defer prepared.release();
        const view = prepared.view;
        const tag = if (view.get(Items.key(.damage_resistant))) |component| tag: {
            const bytes = component.value orelse break :tag null;
            const length, const rest = try encoding.read_varint(bytes);
            if (length < 0 or rest.len != @as(usize, @intCast(length))) return error.Corrupt;
            break :tag rest;
        } else game_data.physics.itemResistance(view.kind);
        return self.inTag(damage, tag orelse return false);
    }

    /// Whether a damage type tag of the registry players were sent holds the damage type.
    fn inTag(self: *Hazards, damage: Damage, tag: []const u8) bool {
        const registry = self.deps.client.client.get("minecraft:damage_type") orelse return false;
        const found = registry.tags.find(tag) orelse return false;
        const type_id = switch (damage) {
            inline else => |kind| registry.id("minecraft:" ++ @tagName(kind)),
        } orelse return false;
        return registry.tags.contains(found, type_id);
    }

    fn level(self: *Hazards, world: u32) bodies.body.Level {
        return self.deps.levels.level(world);
    }
};

/// What ItemPhysics.advance calls once an item moved: the effects of the blocks it crossed.
pub const Hook = struct {
    hazards: *Hazards,
    subject: *Subject,

    /// As ItemPhysics takes it.
    pub fn physics(self: *Hook) ItemPhysics.Hook {
        return .{ .context = self, .apply = applyHook };
    }

    fn applyHook(context: *anyopaque, body: *entities.State, on_ground: bool, from: [3]f64) anyerror!void {
        const self: *Hook = @ptrCast(@alignCast(context));
        return self.apply(body, on_ground, from);
    }

    fn apply(self: *Hook, body: *entities.State, on_ground: bool, from: [3]f64) !void {
        const subject = self.subject;
        subject.position = body.position;
        subject.velocity = body.velocity;
        subject.on_ground = on_ground;
        // The move took what held it back.
        subject.stuck = .{ 0, 0, 0 };
        try self.hazards.apply(subject, from);
        body.velocity = subject.velocity;
    }
};

/// An item as the shared block effects' host sees it: not living.
const Context = struct { hazards: *Hazards, subject: *Subject };
const Host = effects.Host(*const Context);

fn hostOf(context: *const Context, level: *const bodies.body.Level) Host {
    return .{
        .context = context,
        .level = level,
        .scratch = &context.hazards.scratch,
        .random = &context.hazards.random,
        .level_random = &context.hazards.level_random,
        // The mobGriefing game rule, which this server keeps at vanilla's default.
        .mob_griefing = true,
        .alive = Answers.alive,
        .fire_immune = Answers.fireImmune,
        .on_position = Answers.onPosition,
        .hurt = Answers.hurt,
        .play_sound = Answers.playSound,
        .destroy_block = Answers.destroyBlock,
        .lower_cauldron = Answers.lowerCauldron,
    };
}

fn subjectOf(subject: *Subject) effects.Subject {
    return .{
        .world = subject.world,
        .position = subject.position,
        .old_position = subject.old_position,
        .on_ground = subject.on_ground,
        .removed = subject.removed,
        .width = 0.25,
        .height = 0.25,
        .velocity = &subject.velocity,
        .fall_distance = &subject.fall_distance,
        .stuck = &subject.stuck,
        .fire_ticks = &subject.fire_ticks,
        .ticks_frozen = &subject.ticks_frozen,
        .in_powder_snow = &subject.in_powder_snow,
    };
}

const Answers = struct {
    fn alive(context: *const Context) bool {
        return !context.subject.removed;
    }
    fn fireImmune(context: *const Context) anyerror!bool {
        return context.hazards.fireImmune(context.subject);
    }
    /// Entity.getOnPos below an item, which keeps no supporting block.
    fn onPosition(context: *const Context, depth: f32) anyerror![3]i32 {
        const position = context.subject.position;
        return .{ bodies.mth.floor(position[0]), bodies.mth.floor(position[1] - depth), bodies.mth.floor(position[2]) };
    }
    fn hurt(context: *const Context, damage: effects.Damage, amount: f32) anyerror!bool {
        const kind: Damage = switch (damage) {
            inline else => |tag| @field(Damage, @tagName(tag)),
        };
        return context.hazards.hurt(context.subject, kind, amount);
    }
    fn playSound(context: *const Context, sound: effects.Sound, volume: f32, pitch: f32) void {
        const subject = context.subject;
        const hazards = context.hazards;
        const name = switch (sound) {
            .generic_burn => "minecraft:entity.generic.burn",
            .generic_extinguish_fire => "minecraft:entity.generic.extinguish_fire",
            .honey_block_slide => "minecraft:block.honey_block.slide",
        };
        hazards.sounds.sound(subject.world, .{ .x = subject.position[0], .y = subject.position[1], .z = subject.position[2] }, name, .neutral, volume, pitch, @bitCast(hazards.sound_seeds.next()), null);
    }
    fn destroyBlock(context: *const Context, position: [3]i32) anyerror!void {
        return context.hazards.deps.block_edits.destroyBlock(context.subject.world, position);
    }
    fn lowerCauldron(context: *const Context, position: [3]i32) anyerror!void {
        return context.hazards.deps.block_edits.lowerCauldron(context.subject.world, position);
    }
};
