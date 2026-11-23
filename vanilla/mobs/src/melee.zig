//! Player.attack: a player's melee hit on a mob or another player, with the attack strength
//! that recharges between swings, critical hits, the weapon's enchantments, knockback, the sweep
//! of a sword, the victim's Thorns, and the weapon wearing down.

const std = @import("std");
const game_data = @import("game_data");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const Items = @import("vanilla_items").items.Items;
const item_data = @import("vanilla_items").item_data;
const attack_effects = @import("vanilla_items").attack_effects;
const enchantment_effects = @import("vanilla_items").enchantment_effects;
const EnchantmentRegistry = @import("vanilla_items").enchantment_registry.EnchantmentRegistry;
const Durability = @import("vanilla_items").item_properties.Durability;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const FallDamage = @import("vanilla_survival").fall_damage.FallDamage;
const PlayerDamage = @import("vanilla_survival").player_damage.PlayerDamage;
const Replication = @import("replication").replication.Replication;
const world_effects = @import("vanilla_blocks").world_effects;
const entity_effects = @import("vanilla_world").entity_effects;
const body = @import("vanilla_bodies").body;
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const Attack = attack_effects.Attack;
const assert = std.debug.assert;

/// What a hit lands on.
pub const Target = union(enum) {
    mob: Mob,
    /// A player, by slot.
    player: usize,
};

/// What a hit is, worked out before it lands. `base` is after attack strength and before a
/// critical hit, as the sweep reads it.
const Hit = struct {
    base: f32,
    enchanted: f32,
    scale: f32,
    strong: bool,
    knockback_hit: bool,
    critical: bool,
    sweep: bool,
    /// A mace falling hard enough smashes.
    smash: bool = false,
    /// How far the attacker fell, for the smash.
    fallen: f32 = 0,

    fn total(self: Hit) f32 {
        return self.base * @as(f32, if (self.critical) 1.5 else 1.0) + self.enchanted;
    }
};

pub const Melee = struct {
    pub const id = "minecraft:melee";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *Players,
        player_states: *PlayerStates,
        mobs: *Mobs,
        inventories: *inventories.Inventories,
        items: *Items,
        menus: *PlayerInventory,
        attributes: *EquipmentAttributes,
        falls: *FallDamage,
        enchantments: *EnchantmentRegistry,
        durability: *Durability,
        client: *ClientRegistries,
        damage: *PlayerDamage,
        replication: *Replication,
    };
    /// What enchantment effects may allocate while working out one attack.
    const scratch_bytes = 16 * 1024;
    /// Most consequences one item's post-attack enchantments have.
    const consequences_max = 16;

    /// Player.attackStrengthTicker, by player slot: ticks since the last attack or change of
    /// held item, and that item, to notice the change.
    const Strength = struct {
        generation: u32 = 0,
        ticker: i32 = 0,
        item: ?inventories.ItemId = null,
        kind: ?u32 = null,
        /// The inventory's revision and the selected slot when the hand was last looked at: the
        /// hand is read again only when either changed.
        revision: ?i32 = null,
        selected: u8 = 0,
    };

    deps: Dependencies,
    strengths: []Strength,
    effects: world_effects.Effects,
    entity: entity_effects.EntityEffects,
    sound_seeds: std.Random.DefaultPrng,
    /// Enchantment and durability randomness, as the level's and the attacker's random sources.
    random: std.Random.DefaultPrng,
    scratch: std.heap.FixedBufferAllocator,
    player_type: u32,
    mace: u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Melee {
        const self = try allocator.create(Melee);
        const strengths = try allocator.alloc(Strength, deps.players.records.len);
        @memset(strengths, .{});
        self.* = .{
            .deps = deps,
            .strengths = strengths,
            .effects = try .init(allocator, deps.players),
            .entity = try .init(allocator, deps.players),
            .sound_seeds = .init(0x696e7465726163),
            .random = .init(0x6d656c6565),
            .scratch = .init(try allocator.alloc(u8, scratch_bytes)),
            .player_type = @intCast(game_data.registry.entityId("minecraft:player").?),
            .mace = @intCast(game_data.registry.itemId("minecraft:mace").?),
        };
        return self;
    }

    /// Player.tick's attack strength: it climbs every tick and starts over when the kind of item
    /// in the main hand changes. Only a different stack is looked into.
    pub fn tick(self: *Melee) !void {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            const handle = player.handle orelse continue;
            const strength = &self.strengths[slot];
            if (strength.generation != handle.generation) strength.* = .{ .generation = handle.generation };
            strength.ticker += 1;
            // Every edit a client sees bumps its inventory's revision.
            const revision = self.deps.menus.states[slot].revision;
            const selected = self.deps.player_states.of(player).selected_slot;
            if (strength.revision == revision and strength.selected == selected) continue;
            strength.revision = revision;
            strength.selected = selected;
            const stack = (try self.deps.inventories.get(self.mainHand(slot))).stack;
            const item = if (stack) |held| held.item else null;
            if (std.meta.eql(item, strength.item)) continue;
            strength.item = item;
            const kind = if (stack) |held| try self.deps.items.kind(held) else null;
            if (kind != strength.kind) strength.ticker = 0;
            strength.kind = kind;
        }
    }

    fn mainHand(self: *Melee, slot: usize) inventories.Slot {
        const player = &self.deps.players.records[slot];
        return .{ .owner = player.uuid, .index = 36 + @as(u16, self.deps.player_states.of(player).selected_slot) };
    }

    /// Player.attack, from the player in `slot`.
    pub fn attack(self: *Melee, slot: usize, target: Target) !void {
        const player = &self.deps.players.records[slot];
        const state = self.deps.player_states.of(player);
        if (state.gamemode == .spectator or state.health <= 0) return;
        if (target == .player) assert(target.player != slot);
        const held_slot = self.mainHand(slot);
        const held = try self.deps.inventories.get(held_slot);
        const worn_kind = blk: {
            const pinned: ?Items.Prepared = if (held.stack) |stack| try self.deps.items.acquire(stack) else null;
            defer if (pinned) |value| value.release();
            const weapon: ?item_data.View = if (pinned) |value| value.view else null;
            break :blk try self.strike(slot, weapon, target);
        };
        // ItemStack.postHurtEnemy, once the weapon's view is let go.
        if (worn_kind) |kind| try self.wearWeapon(slot, held_slot, held, kind);
    }

    /// Player.attack from the strength scale to the hit's consequences. Returns the weapon's kind
    /// if it hurt the target, for the weapon to wear.
    fn strike(self: *Melee, slot: usize, weapon: ?item_data.View, target: Target) !?u32 {
        const player = &self.deps.players.records[slot];
        self.scratch.reset();
        const effects = try Attack.start(.{
            .effects = &self.deps.enchantments.effects,
            .item_tags = &self.deps.items.deps.definitions.tags,
            .registries = &self.deps.client.client,
            .damage_type = "minecraft:player_attack",
            .attacker = player,
            .direct_type = self.player_type,
            .random = self.random.random(),
            .scratch = &self.scratch,
        });
        const hit = try self.prepare(slot, weapon, &effects, target) orelse return null;
        const health = self.healthOf(target);
        if (!try self.hurt(slot, weapon, &effects, target, hit.total(), if (hit.smash) .mace_smash else .player_attack)) {
            self.sound(slot, "minecraft:entity.player.attack.nodamage");
            return null;
        }
        try self.landed(slot, weapon, &effects, target, hit);
        // Player.attack's damage indicator, a particle for each heart dealt past the first.
        const dealt = health - self.healthOf(target);
        if (dealt > 2) {
            const box = self.boxOf(target);
            const at = self.positionOf(target);
            self.effects.particles(player.world, .{
                .particle = .damage_indicator,
                .at = .{ .x = at[0], .y = box.min[1] + (box.max[1] - box.min[1]) * 0.5, .z = at[2] },
                .count = @intFromFloat(dealt * 0.5),
                .offset = .{ 0.1, 0, 0.1 },
                .speed = 0.2,
            });
        }
        return if (weapon) |view| view.kind else null;
    }

    /// Player.attack up to the hurt: the strength scale, enchantment damage, and whether the hit
    /// is critical, sweeps or knocks back. Null if it deals nothing.
    fn prepare(self: *Melee, slot: usize, weapon: ?item_data.View, effects: *const Attack, target: Target) !?Hit {
        const player = &self.deps.players.records[slot];
        const attribute: f32 = @floatCast(try self.deps.attributes.value(slot, "minecraft:attack_damage"));
        var enchanted = try effects.damage(weapon, self.typeOf(target), attribute) - attribute;
        const speed = try self.deps.attributes.value(slot, "minecraft:attack_speed");
        // Player.getAttackStrengthScale(0.5).
        const delay: f32 = @floatCast(1.0 / speed * 20.0);
        const scale = mth.clamp((@as(f32, @floatFromInt(self.strengths[slot].ticker)) + 0.5) / delay, 0, 1);
        const base = attribute * (0.2 + scale * scale * 0.8);
        enchanted *= scale;
        self.strengths[slot].ticker = 0;
        if (!(base > 0 or enchanted > 0)) return null;
        const strong = scale > 0.9;
        const knockback_hit = player.flags.sprinting and strong;
        if (knockback_hit) self.sound(slot, "minecraft:entity.player.attack.knockback");
        // MaceItem.getAttackDamageBonus, on the strength-scaled damage.
        const fallen: f32 = @floatCast(self.deps.falls.distance(slot));
        const smashing = self.smashes(slot, weapon);
        const bonus = if (smashing) try self.smashBonus(weapon.?, effects, target, fallen) else 0;
        // Falling and not on the ground or sprinting.
        const critical = strong and fallen > 0 and !player.on_ground and !player.flags.sprinting;
        const sweeps = strong and !critical and !knockback_hit and player.on_ground and try self.walksSlowly(slot) and self.holdsSword(weapon);
        return .{ .base = base + bonus, .enchanted = enchanted, .scale = scale, .strong = strong, .knockback_hit = knockback_hit, .critical = critical, .sweep = sweeps, .smash = smashing, .fallen = fallen };
    }

    /// MaceItem.canSmashAttack: a mace, fallen more than a block and a half, not gliding.
    fn smashes(self: *const Melee, slot: usize, weapon: ?item_data.View) bool {
        const view = weapon orelse return false;
        if (view.kind != self.mace) return false;
        return self.deps.falls.distance(slot) > 1.5 and !self.deps.players.records[slot].flags.gliding;
    }

    /// The smash's damage by the fall: four a block for three, two a block for five more, then
    /// one a block, and Density's on top.
    fn smashBonus(self: *const Melee, weapon: item_data.View, effects: *const Attack, target: Target, fallen: f32) !f32 {
        const by_fall = if (fallen <= 3) 4 * fallen else if (fallen <= 8) 12 + 2 * (fallen - 3) else 22 + fallen - 8;
        return by_fall + try effects.smashDamagePerBlock(weapon, self.typeOf(target)) * fallen;
    }

    /// MaceItem.hurtEnemy and postHurtEnemy: the attacker stops falling and takes no fall, the
    /// ground thuds, and everything near the target is thrown back.
    fn smash(self: *Melee, slot: usize, target: Target, fallen: f32) !void {
        const player = &self.deps.players.records[slot];
        try self.deps.damage.setMotion(slot, .{ player.known_movement[0], 0.01, player.known_movement[2] });
        self.deps.falls.reset(slot);
        const grounded = switch (target) {
            .mob => |mob| mob.motion.on_ground,
            .player => |victim| self.deps.players.records[victim].on_ground,
        };
        self.sound(slot, if (!grounded) "minecraft:item.mace.smash_air" else if (fallen > 5) "minecraft:item.mace.smash_ground_heavy" else "minecraft:item.mace.smash_ground");
        const at = self.positionOf(target);
        self.effects.worldEvent(player.world, .{ .x = mth.floor(at[0]), .y = mth.floor(at[1] - 0.2), .z = mth.floor(at[2]) }, 2013, 750);
        try self.smashKnockback(slot, target, fallen);
    }

    /// MaceItem.knockback: the living within 3.5 blocks of the target, but the attacker and the
    /// target, are thrown up and away, harder after a long fall.
    fn smashKnockback(self: *Melee, slot: usize, target: Target, fallen: f32) !void {
        const player = &self.deps.players.records[slot];
        const center = self.positionOf(target);
        const box = self.boxOf(target);
        const reach: body.Box = .{ .min = .{ box.min[0] - 3.5, box.min[1] - 3.5, box.min[2] - 3.5 }, .max = .{ box.max[0] + 3.5, box.max[1] + 3.5, box.max[2] + 3.5 } };
        const scale: f64 = if (fallen > 5) 2 else 1;
        var knock: struct { mobs: *Mobs, target: Target, center: [3]f64, scale: f64 } = .{ .mobs = self.deps.mobs, .target = target, .center = center, .scale = scale };
        try self.deps.mobs.each(player.world, reach, &knock, struct {
            fn visit(context: *@TypeOf(knock), mob: Mob) anyerror!bool {
                const mobs = context.mobs;
                if (!mob.alive() or (context.target == .mob and context.target.mob.same(mob))) return false;
                const strength = smashStrength(context.center, mob.motion.position, context.scale) * (1 - mobs.traits(mob.entity.species).attribute(.knockback_resistance));
                if (strength <= 0) return false;
                const away = living.normalize(.{ mob.motion.position[0] - context.center[0], mob.motion.position[1] - context.center[1], mob.motion.position[2] - context.center[2] });
                mob.motion.velocity = .{ mob.motion.velocity[0] + away[0] * strength, mob.motion.velocity[1] + 0.7, mob.motion.velocity[2] + away[2] * strength };
                mob.entity.has_impulse = true;
                mobs.rouseMob(mob);
                return false;
            }
        }.visit);
        var players = self.deps.players.nearby(player.world, .{ .x = center[0], .y = 0, .z = center[2] }, 1);
        while (players.next()) |other| {
            if (other == slot or (target == .player and target.player == other)) continue;
            const candidate = &self.deps.players.records[other];
            if (candidate.world != player.world or self.deps.player_states.of(candidate).gamemode == .spectator or !playerBox(candidate).intersects(reach)) continue;
            const at: [3]f64 = .{ candidate.position.x, candidate.position.y, candidate.position.z };
            const strength = smashStrength(center, at, scale) * (1 - try self.deps.attributes.value(other, "minecraft:knockback_resistance"));
            if (strength <= 0) continue;
            const away = living.normalize(.{ at[0] - center[0], at[1] - center[1], at[2] - center[2] });
            try self.deps.damage.push(other, .{ away[0] * strength, 0.7, away[2] * strength });
        }
    }

    /// Player.attack after a hurt that took: knockback, the sweep, sounds, sparks, and the
    /// post-attack enchantments of the victim's gear and the weapon.
    fn landed(self: *Melee, slot: usize, weapon: ?item_data.View, effects: *const Attack, target: Target, hit: Hit) !void {
        const player = &self.deps.players.records[slot];
        const yaw = player.rotation.yaw * (std.math.pi / 180.0);
        const attribute: f32 = @floatCast(try self.deps.attributes.value(slot, "minecraft:attack_knockback"));
        const knockback = try effects.knockback(weapon, self.typeOf(target), attribute) + @as(f32, if (hit.knockback_hit) 1.0 else 0.0);
        if (knockback > 0) try self.push(target, knockback * 0.5, mth.sin(yaw), -mth.cos(yaw));
        if (hit.sweep) try self.sweep(slot, weapon, effects, target, hit);
        if (hit.critical) {
            self.sound(slot, "minecraft:entity.player.attack.crit");
            self.animate(slot, target, .critical_hit);
        }
        if (!hit.critical and !hit.sweep) self.sound(slot, if (hit.strong) "minecraft:entity.player.attack.strong" else "minecraft:entity.player.attack.weak");
        if (hit.enchanted > 0) self.animate(slot, target, .enchanted_hit);
        if (hit.smash) try self.smash(slot, target, hit.fallen);
        try self.postAttack(slot, weapon, effects, target);
    }

    /// Player.attack's sweep: every other living thing in reach of the target's box inflated by
    /// (1, 0.25, 1) and within 3 blocks of the attacker, mobs in the order vanilla finds them and
    /// then players. The mobs' places and the players' spatial index give the few in the cells under
    /// the box, so a sweep looks at nothing farther.
    fn sweep(self: *Melee, slot: usize, weapon: ?item_data.View, effects: *const Attack, target: Target, hit: Hit) !void {
        const player = &self.deps.players.records[slot];
        const ratio: f32 = @floatCast(try self.deps.attributes.value(slot, "minecraft:sweeping_damage_ratio"));
        const amount = 1.0 + ratio * hit.base;
        const box = self.boxOf(target);
        const reach: body.Box = .{
            .min = .{ box.min[0] - 1, box.min[1] - 0.25, box.min[2] - 1 },
            .max = .{ box.max[0] + 1, box.max[1] + 0.25, box.max[2] + 1 },
        };
        switch (target) {
            .mob, .player => {
                var swept: struct { melee: *Melee, slot: usize, weapon: @TypeOf(weapon), effects: @TypeOf(effects), amount: @TypeOf(amount), scale: @TypeOf(hit.scale) } = .{ .melee = self, .slot = slot, .weapon = weapon, .effects = effects, .amount = amount, .scale = hit.scale };
                const Sweep = struct {
                    fn visit(context: *@TypeOf(swept), mob: Mob) anyerror!bool {
                        try context.melee.sweepOne(context.slot, context.weapon, context.effects, .{ .mob = mob }, context.amount, context.scale);
                        return false;
                    }
                };
                switch (target) {
                    .mob => |mob| try self.deps.mobs.near(mob, reach, .living, &swept, Sweep.visit),
                    .player => try self.deps.mobs.each(player.world, reach, &swept, Sweep.visit),
                }
            },
        }
        var players = self.deps.players.nearby(player.world, .{ .x = (reach.min[0] + reach.max[0]) / 2, .y = 0, .z = (reach.min[2] + reach.max[2]) / 2 }, 1);
        while (players.next()) |other| {
            if (other == slot or std.meta.eql(target, Target{ .player = other })) continue;
            const candidate = &self.deps.players.records[other];
            if (candidate.world != player.world or self.deps.player_states.of(candidate).gamemode == .spectator) continue;
            if (!playerBox(candidate).intersects(reach)) continue;
            try self.sweepOne(slot, weapon, effects, .{ .player = other }, amount, hit.scale);
        }
        self.sound(slot, "minecraft:entity.player.attack.sweep");
        self.sweepParticle(slot);
    }

    /// One of a sweep's victims: within 3 blocks of the attacker, it takes the sweep's damage
    /// with the weapon's enchantments for it, scaled by the attack strength.
    fn sweepOne(self: *Melee, slot: usize, weapon: ?item_data.View, effects: *const Attack, victim: Target, amount: f32, scale: f32) !void {
        const player = &self.deps.players.records[slot];
        const at = self.positionOf(victim);
        const dx = player.position.x - at[0];
        const dy = player.position.y - at[1];
        const dz = player.position.z - at[2];
        if (dx * dx + dy * dy + dz * dz >= 9.0) return;
        const damage = try effects.damage(weapon, self.typeOf(victim), amount) * scale;
        if (!try self.hurt(slot, weapon, effects, victim, damage, .player_attack)) return;
        const yaw = player.rotation.yaw * (std.math.pi / 180.0);
        try self.push(victim, 0.4, mth.sin(yaw), -mth.cos(yaw));
        try self.postAttack(slot, weapon, effects, victim);
    }

    /// Player.sweepAttack: one particle ahead of the attacker at half its height.
    fn sweepParticle(self: *Melee, slot: usize) void {
        const player = &self.deps.players.records[slot];
        const yaw = player.rotation.yaw * (std.math.pi / 180.0);
        const ahead = -mth.sin(yaw);
        const side = mth.cos(yaw);
        const height: f64 = if (player.flags.sneaking) 1.5 else 1.8;
        self.effects.particles(player.world, .{
            .particle = .sweep_attack,
            .at = .{ .x = player.position.x + ahead, .y = player.position.y + height * 0.5, .z = player.position.z + side },
            .count = 0,
            .offset = .{ ahead, 0, side },
        });
    }

    /// EnchantmentHelper.doPostAttackEffects: the victim's gear first, then the attacker's weapon
    /// in the main hand.
    fn postAttack(self: *Melee, slot: usize, weapon: ?item_data.View, effects: *const Attack, target: Target) !void {
        if (target == .player) try self.victimGear(slot, effects, target.player);
        const view = weapon orelse return;
        var consequences: [consequences_max]enchantment_effects.Consequence = undefined;
        const count = try effects.postAttack(view, 0, .attacker, self.typeOf(target), &consequences);
        for (consequences[0..count]) |consequence| switch (consequence.affected) {
            .victim => switch (consequence.action) {
                .ignite_seconds => |seconds| try self.ignite(target, seconds),
                // No vanilla enchantment on a weapon hurts its victim outright or wears its gear.
                .damage, .item_damage => {},
            },
            // A weapon's own enchantments never act on its holder in vanilla.
            .attacker, .damaging_entity => {},
        };
    }

    /// The post-attack enchantments of what a player victim wears and holds, in vanilla's slot
    /// order: Thorns hurts the attacker and wears the piece it is on.
    fn victimGear(self: *Melee, slot: usize, effects: *const Attack, victim: usize) !void {
        const owner = self.deps.players.records[victim].uuid;
        const selected = self.deps.player_states.of(&self.deps.players.records[victim]).selected_slot;
        // EquipmentSlot.VALUES: main hand, off hand, feet, legs, chest, head.
        const slots = [_]struct { index: u16, code: u3 }{ .{ .index = 36 + @as(u16, selected), .code = 0 }, .{ .index = 45, .code = 1 }, .{ .index = 8, .code = 5 }, .{ .index = 7, .code = 4 }, .{ .index = 6, .code = 3 }, .{ .index = 5, .code = 2 } };
        for (slots) |worn| {
            const at: inventories.Slot = .{ .owner = owner, .index = worn.index };
            const stack = (try self.deps.inventories.get(at)).stack orelse continue;
            var consequences: [consequences_max]enchantment_effects.Consequence = undefined;
            const count = blk: {
                const pinned = try self.deps.items.acquire(stack);
                defer pinned.release();
                break :blk try effects.postAttack(pinned.view, worn.code, .victim, self.player_type, &consequences);
            };
            for (consequences[0..count]) |consequence| switch (consequence.affected) {
                .attacker, .damaging_entity => switch (consequence.action) {
                    .damage => |dealt| _ = try self.deps.damage.hurt(slot, self.thorns(victim, dealt.damage_type), dealt.amount),
                    .ignite_seconds => |seconds| try self.deps.damage.ignite(slot, seconds),
                    .item_damage => |amount| try self.wearWorn(victim, at, amount),
                },
                .victim => switch (consequence.action) {
                    .item_damage => |amount| try self.wearWorn(victim, at, amount),
                    .ignite_seconds => |seconds| try self.deps.damage.ignite(victim, seconds),
                    .damage => |dealt| _ = try self.deps.damage.hurt(victim, self.thorns(victim, dealt.damage_type), dealt.amount),
                },
            };
        }
    }

    /// Thorns' damage source: the wearer causes and deals it.
    fn thorns(self: *Melee, wearer: usize, name: []const u8) PlayerDamage.Source {
        const player = &self.deps.players.records[wearer];
        const damage_type = std.meta.stringToEnum(mob_state.DamageType, name["minecraft:".len..]) orelse .thorns;
        const network = entity_effects.playerId(wearer) + 1;
        return .{ .type = damage_type, .attacker = wearer, .cause_id = network, .direct_id = network, .position = .{ player.position.x, player.position.y, player.position.z } };
    }

    /// change_item_damage on something a player wears: it wears as hurtAndBreak would, and not
    /// in creative.
    fn wearWorn(self: *Melee, wearer: usize, at: inventories.Slot, amount: i32) !void {
        if (amount <= 0) return;
        const player = &self.deps.players.records[wearer];
        if (self.deps.player_states.of(player).gamemode == .creative) return;
        const held = try self.deps.inventories.get(at);
        const stack = held.stack orelse return;
        self.scratch.reset();
        const code: u3 = if (at.index == 45) 1 else if (at.index >= 36) 0 else @intCast(at.index - 3);
        const worn = try self.deps.durability.wear(stack, .{ .amount = amount, .slot = code, .actor = player, .random = self.random.random(), .scratch = &self.scratch });
        if (std.meta.eql(worn, held.stack)) return;
        const committed = try self.deps.inventories.set(at, held.revision, worn);
        assert(committed);
        self.deps.menus.changed(wearer);
    }

    /// ItemStack.postHurtEnemy: a weapon wears by its weapon component's damage per attack,
    /// except in creative, and the held stack takes the result.
    fn wearWeapon(self: *Melee, slot: usize, held_slot: inventories.Slot, held: inventories.Contents, kind: u32) !void {
        const player = &self.deps.players.records[slot];
        const weapon = game_data.physics.itemWeapon(kind) orelse return;
        if (weapon.damage_per_attack == 0 or self.deps.player_states.of(player).gamemode == .creative) return;
        const stack = held.stack.?;
        self.scratch.reset();
        const worn = try self.deps.durability.wear(stack, .{
            .amount = weapon.damage_per_attack,
            .slot = 0,
            .actor = player,
            .random = self.random.random(),
            .scratch = &self.scratch,
        });
        if (std.meta.eql(worn, held.stack)) return;
        const committed = try self.deps.inventories.set(held_slot, held.revision, worn);
        assert(committed);
        self.deps.menus.changed(slot);
    }

    // What a hit needs of its target.

    fn hurt(self: *Melee, slot: usize, weapon: ?item_data.View, effects: *const Attack, target: Target, amount: f32, damage_type: mob_state.DamageType) !bool {
        const player = &self.deps.players.records[slot];
        const from: [3]f64 = .{ player.position.x, player.position.y, player.position.z };
        return switch (target) {
            .mob => |mob| self.deps.mobs.hurt(mob, .{ .type = damage_type, .attacker = @intCast(slot), .source = from }, amount),
            .player => |victim| blk: {
                const network = entity_effects.playerId(slot) + 1;
                const disable = if (weapon) |view| if (game_data.physics.itemWeapon(view.kind)) |held| held.disable_blocking_seconds else 0 else 0;
                break :blk self.deps.damage.hurt(victim, .{ .type = damage_type, .attacker = slot, .cause_id = network, .direct_id = network, .position = from, .attack = effects, .weapon = weapon, .melee = true, .disable_seconds = disable }, amount);
            },
        };
    }

    fn push(self: *Melee, target: Target, strength: f64, x: f64, z: f64) !void {
        switch (target) {
            .mob => |mob| self.deps.mobs.knockback(mob, strength, x, z),
            .player => |victim| try self.deps.damage.knockback(victim, strength, x, z),
        }
    }

    fn ignite(self: *Melee, target: Target, seconds: f32) !void {
        switch (target) {
            .mob => |mob| self.deps.mobs.ignite(mob, seconds),
            .player => |victim| try self.deps.damage.ignite(victim, seconds),
        }
    }

    /// ServerPlayer.crit and magicCrit: the sparks, for those who see the attacker. A mob's
    /// viewers are near enough the same and take them with its other packets.
    fn animate(self: *Melee, slot: usize, target: Target, animation: Mobs.Animation) void {
        switch (target) {
            .mob => |mob| self.deps.mobs.animate(mob, animation),
            .player => |victim| self.entity.send(self.deps.replication.viewers(slot), slot, .{ .animation = .{ .id = entity_effects.playerId(victim), .animation = @backingInt(animation) } }),
        }
    }

    fn typeOf(self: *const Melee, target: Target) u32 {
        return switch (target) {
            .mob => |mob| self.deps.mobs.traits(mob.entity.species).entity_type,
            .player => self.player_type,
        };
    }

    fn healthOf(self: *Melee, target: Target) f32 {
        return switch (target) {
            .mob => |mob| mob.living.health,
            .player => |victim| self.deps.player_states.of(&self.deps.players.records[victim]).health,
        };
    }

    fn positionOf(self: *const Melee, target: Target) [3]f64 {
        return switch (target) {
            .mob => |mob| mob.motion.position,
            .player => |victim| blk: {
                const position = self.deps.players.records[victim].position;
                break :blk .{ position.x, position.y, position.z };
            },
        };
    }

    fn boxOf(self: *const Melee, target: Target) body.Box {
        return switch (target) {
            .mob => |mob| living.box(self.deps.mobs, mob),
            .player => |victim| playerBox(&self.deps.players.records[victim]),
        };
    }

    /// Player.attack's sweep needs the attacker to move slower than 2.5 times its speed a tick,
    /// by what its client last said it moved.
    fn walksSlowly(self: *Melee, slot: usize) !bool {
        const moved = self.deps.players.records[slot].known_movement;
        const speed = try self.deps.attributes.value(slot, "minecraft:movement_speed") * 2.5;
        return moved[0] * moved[0] + moved[2] * moved[2] < speed * speed;
    }

    fn holdsSword(self: *const Melee, weapon: ?item_data.View) bool {
        const view = weapon orelse return false;
        const tags = &self.deps.items.deps.definitions.tags;
        const swords = tags.find("minecraft:swords") orelse return false;
        return tags.contains(swords, view.kind);
    }

    /// Level.playSound with no player: everyone nearby hears it, the attacker too.
    fn sound(self: *Melee, slot: usize, name: []const u8) void {
        const player = &self.deps.players.records[slot];
        self.effects.sound(player.world, player.position, name, .players, 1, 1, @bitCast(self.sound_seeds.next()), null);
    }
};

/// The push a smash gives at a distance from its target: none past 3.5 blocks.
fn smashStrength(center: [3]f64, at: [3]f64, scale: f64) f64 {
    const dx = at[0] - center[0];
    const dy = at[1] - center[1];
    const dz = at[2] - center[2];
    const distance = @sqrt(dx * dx + dy * dy + dz * dz);
    if (distance * distance > 12.25) return 0;
    return (3.5 - distance) * 0.7 * scale;
}

/// A standing player's box: 0.6 wide, 1.8 tall, or 1.5 sneaking.
fn playerBox(player: *const @import("players").player_state.Player) body.Box {
    const height: f64 = if (player.flags.sneaking) 1.5 else 1.8;
    const at = player.position;
    return .{ .min = .{ at.x - 0.3, at.y, at.z - 0.3 }, .max = .{ at.x + 0.3, at.y + height, at.z + 0.3 } };
}
