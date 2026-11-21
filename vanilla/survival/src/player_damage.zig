//! The damage players take, as ServerPlayer.hurtServer and LivingEntity.hurtServer deal it:
//! invulnerability after a hit, armor and its toughness, the enchantments that pierce armor or
//! protect from damage, armor wearing down, knockback, the hurt tilt and sounds, burning, and
//! death. Whatever hurts a player, a fall or an attack, comes through `hurt`.

const std = @import("std");
const game_data = @import("game_data");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const Player = @import("players").player_state.Player;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const Items = @import("vanilla_items").items.Items;
const item_data = @import("vanilla_items").item_data;
const attack_effects = @import("vanilla_items").attack_effects;
const EnchantmentRegistry = @import("vanilla_items").enchantment_registry.EnchantmentRegistry;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const Durability = @import("vanilla_items").item_properties.Durability;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const Replication = @import("replication").replication.Replication;
const world_effects = @import("vanilla_world").world_effects;
const entity_effects = @import("vanilla_world").entity_effects;
const item_using = @import("vanilla_items").item_using;
const ItemUsing = item_using.ItemUsing;
const ItemCooldowns = @import("vanilla_items").item_cooldowns.ItemCooldowns;
const mth = @import("vanilla_bodies").mth;
const damage_types = @import("damage_types.zig");

const DamageType = damage_types.DamageType;
const DamageTypes = damage_types.DamageTypes;
const Flags = damage_types.Flags;
const assert = std.debug.assert;

/// Armor slots in the order LivingEntity.hurtArmor wears them: feet, legs, chest, head.
const armor_slots = [_]u16{ 8, 7, 6, 5 };

pub const PlayerDamage = struct {
    pub const id = "minecraft:player_damage";
    pub const Configuration = struct {
        /// The server.properties pvp setting: whether players can hurt each other.
        pvp: bool = true,
        seed: u64 = 0,
        scratch_bytes: usize = 16 * 1024,
    };
    pub const Dependencies = struct {
        players: *Players,
        player_states: *PlayerStates,
        inventories: *inventories.Inventories,
        menus: *PlayerInventory,
        items: *Items,
        enchantments: *EnchantmentRegistry,
        attributes: *EquipmentAttributes,
        durability: *Durability,
        client: *ClientRegistries,
        damage_types: *DamageTypes,
        replication: *Replication,
        using: *ItemUsing,
        cooldowns: *ItemCooldowns,
    };

    /// What hurts a player.
    pub const Source = struct {
        type: DamageType,
        /// The player who caused it, by slot.
        attacker: ?usize = null,
        /// Network ids plus one of what caused the damage and what dealt it, zero for none.
        cause_id: i32 = 0,
        direct_id: i32 = 0,
        /// DamageSource.getSourcePosition: where knockback pushes away from.
        position: ?[3]f64 = null,
        /// Which way knockback pushes instead, as projectiles say it.
        knockback: ?[2]f64 = null,
        /// The attack's enchantment hooks and its weapon, for Breach.
        attack: ?*const attack_effects.Attack = null,
        weapon: ?item_data.View = null,
        /// Whether a living attacker struck directly, which a shield pushes back.
        melee: bool = false,
        /// The weapon component's disable_blocking_for_seconds of the attacker's weapon.
        disable_seconds: f32 = 0,
        /// An arrow that pierces, which shields do not stop.
        piercing: bool = false,
    };

    /// LivingEntity's hurt state, by player slot, for the life it belongs to.
    const Living = struct {
        generation: u32 = 0,
        life: u32 = 0,
        invulnerable_time: i32 = 0,
        last_hurt: f32 = 0,
        /// Entity.remainingFireTicks.
        fire_ticks: i32 = 0,
        /// The motion hits gave this tick, which the client takes at its end (hurtMarked).
        motion: [3]f64 = @splat(0),
        marked: bool = false,
        /// What the tick sends of this tick's hits: each damage event, the tilt, and the sounds
        /// of hurts and a death. More than there is room for send what came first early.
        events: [4]entity_effects.Packet = undefined,
        event_count: u3 = 0,
        tilt: ?f32 = null,
        /// Sounds at the player: a hurt or a death, and a shield's block or disabling.
        sounds: [4]Sound = undefined,
        sound_count: u3 = 0,
        died: bool = false,
    };

    deps: Dependencies,
    configuration: Configuration,
    living: []Living,
    random: std.Random.DefaultPrng,
    scratch: std.heap.FixedBufferAllocator,
    effects: world_effects.Effects,
    entity: entity_effects.EntityEffects,
    player_type: u32,
    elytra: u32,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*PlayerDamage {
        if (configuration.scratch_bytes == 0) return error.InvalidConfiguration;
        const self = try allocator.create(PlayerDamage);
        const living = try allocator.alloc(Living, deps.players.records.len);
        @memset(living, .{});
        self.* = .{
            .deps = deps,
            .configuration = configuration,
            .living = living,
            .random = .init(configuration.seed),
            .scratch = .init(try allocator.alloc(u8, configuration.scratch_bytes)),
            .effects = try .init(allocator, deps.players),
            .entity = try .init(allocator, deps.players),
            .player_type = @intCast(game_data.registry.entityId("minecraft:player").?),
            .elytra = @intCast(game_data.registry.itemId("minecraft:elytra").?),
        };
        return self;
    }

    /// The hurt state of the player in a slot, started over for a new connection or life.
    fn livingOf(self: *PlayerDamage, slot: usize) *Living {
        const player = &self.deps.players.records[slot];
        const living = &self.living[slot];
        const generation = if (player.handle) |handle| handle.generation else 0;
        if (living.generation != generation or living.life != player.life) living.* = .{ .generation = generation, .life = player.life };
        return living;
    }

    /// LivingEntity.hurtServer for a player. Returns whether the damage took.
    pub fn hurt(self: *PlayerDamage, slot: usize, source: Source, amount: f32) !bool {
        const flags = self.deps.damage_types.flagsOf(source.type);
        if (!self.vulnerable(slot, source, flags)) return false;
        const state = self.deps.player_states.of(&self.deps.players.records[slot]);
        var value = @max(amount, 0);
        if (value == 0) return false;
        const blocked = try self.block(slot, source, flags, value);
        value -= blocked;
        if (std.math.isNan(value) or std.math.isInf(value)) value = std.math.floatMax(f32);
        const living = self.livingOf(slot);
        var full = true;
        if (living.invulnerable_time > 10 and !flags.bypasses_cooldown) {
            if (value <= living.last_hurt) return false;
            try self.actuallyHurt(slot, source, flags, value - living.last_hurt);
            living.last_hurt = value;
            full = false;
        } else {
            living.last_hurt = value;
            living.invulnerable_time = 20;
            try self.actuallyHurt(slot, source, flags, value);
        }
        if (full) try self.react(slot, source, flags, blocked, value);
        if (state.health <= 0) {
            self.die(slot);
        } else if (full and value > 0) {
            self.queueSound(slot, hurtSound(source.type), 1, self.voicePitch());
        }
        return blocked <= 0 or value > 0;
    }

    /// LivingEntity.applyItemBlocking: what a raised item that blocks attacks takes off a hit
    /// from in front, how it wears for it, and how it pushes a melee attacker back, which an axe
    /// answers by disabling it.
    fn block(self: *PlayerDamage, slot: usize, source: Source, flags: Flags, amount: f32) !f32 {
        const use = self.deps.using.of(slot) orelse return 0;
        const blocks = game_data.physics.itemBlocksAttacks(use.kind) orelse return 0;
        // getItemBlockingWith: raised for at least the block delay.
        if (use.ticks < @as(i32, @intFromFloat(@round(blocks.block_delay_seconds * 20.0)))) return 0;
        if (blocks.bypassed_by.len > 0 and try self.inDamageTag(source.type, blocks.bypassed_by)) return 0;
        if (source.piercing) return 0;
        const player = &self.deps.players.records[slot];
        // The angle between the look and where the hit came from, flat; none blocks from nowhere.
        var angle: f64 = std.math.pi;
        if (source.position) |from| {
            const dx = from[0] - player.position.x;
            const dz = from[2] - player.position.z;
            const length = @sqrt(dx * dx + dz * dz);
            const yaw = player.rotation.yaw * 0.017453292;
            if (length >= 1.0e-4) angle = std.math.acos(std.math.clamp((dx * -@as(f64, mth.sin(yaw)) + dz * @as(f64, mth.cos(yaw))) / length, -1, 1));
        }
        var total: f32 = 0;
        for (0..blocks.reductionCount()) |index| {
            const reduction = blocks.reduction(index);
            if (angle > @as(f64, reduction.horizontal_angle * 0.017453292) or reduction.typed) continue;
            total += std.math.clamp(reduction.base + reduction.factor * amount, 0, amount);
        }
        const blocked = std.math.clamp(total, 0, amount);
        // BlocksAttacks.hurtBlockingItem.
        const wear: i32 = if (blocked < blocks.damage_threshold) 0 else @intFromFloat(@floor(blocks.damage_base + blocks.damage_factor * blocked));
        if (wear > 0) try self.wearHeld(slot, use.hand, wear);
        if (!flags.projectile and source.melee) try self.pushBack(slot, source, use.kind, blocks);
        return blocked;
    }

    /// LivingEntity.blockUsingItem for a melee attacker: it is pushed away, and a weapon that
    /// disables blocking puts the item on cooldown and lowers it.
    fn pushBack(self: *PlayerDamage, slot: usize, source: Source, kind: u32, blocks: game_data.physics_data.BlocksAttacks) !void {
        const player = &self.deps.players.records[slot];
        if (source.attacker) |attacker| {
            const other = &self.deps.players.records[attacker];
            try self.knockback(attacker, 0.5, player.position.x - other.position.x, player.position.z - other.position.z);
        }
        const ticks: i32 = @intFromFloat(@round(source.disable_seconds * blocks.disable_cooldown_scale * 20.0));
        if (ticks <= 0) return;
        self.deps.cooldowns.set(slot, kind, ticks);
        self.deps.using.stop(slot);
        if (blocks.disabled_sound.len > 0) self.queueSound(slot, blocks.disabled_sound, 0.8, self.shieldPitch());
    }

    /// Wears the item a player holds in a hand.
    fn wearHeld(self: *PlayerDamage, slot: usize, hand: item_using.Hand, amount: i32) !void {
        const player = &self.deps.players.records[slot];
        if (self.deps.player_states.of(player).gamemode == .creative) return;
        const index: u16 = if (hand == .off) 45 else 36 + @as(u16, self.deps.player_states.of(player).selected_slot);
        const at: inventories.Slot = .{ .owner = player.uuid, .index = index };
        const held = try self.deps.inventories.get(at);
        const stack = held.stack orelse return;
        self.scratch.reset();
        const worn = try self.deps.durability.wear(stack, .{ .amount = amount, .slot = if (hand == .off) 1 else 0, .actor = player, .random = self.random.random(), .scratch = &self.scratch });
        if (std.meta.eql(worn, held.stack)) return;
        const committed = try self.deps.inventories.set(at, held.revision, worn);
        assert(committed);
        self.deps.menus.changed(slot);
    }

    /// Whether a damage type is in a tag of the damage type registry.
    fn inDamageTag(self: *PlayerDamage, damage_type: DamageType, tag: []const u8) !bool {
        const registry = self.deps.client.client.get("minecraft:damage_type") orelse return error.MissingDamageRegistry;
        const found = registry.tags.find(tag) orelse return false;
        return registry.tags.contains(found, registry.id(DamageTypes.name(damage_type)) orelse return false);
    }

    /// Player.isInvulnerableTo, the ability to be harmed, and the pvp rule.
    fn vulnerable(self: *PlayerDamage, slot: usize, source: Source, flags: Flags) bool {
        const player = &self.deps.players.records[slot];
        if (player.stage != .ready or !player.loaded) return false;
        const state = self.deps.player_states.of(player);
        if (state.health <= 0) return false;
        // Abilities.invulnerable, in creative and spectator.
        if ((state.gamemode == .creative or state.gamemode == .spectator) and !flags.bypasses_invulnerability) return false;
        if (source.attacker) |attacker| if (attacker != slot and !self.configuration.pvp) return false;
        return true;
    }

    /// Player.actuallyHurt: armor, then protection, then what is left off the health.
    fn actuallyHurt(self: *PlayerDamage, slot: usize, source: Source, flags: Flags, amount: f32) !void {
        var value = amount;
        if (!flags.bypasses_armor) {
            try self.wearArmor(slot, flags, value);
            value = try self.afterArmor(slot, source, value);
        }
        value = try self.afterProtection(slot, source, flags, value);
        if (value <= 0) return;
        const state = self.deps.player_states.of(&self.deps.players.records[slot]);
        state.health = @max(0, state.health - value);
    }

    /// CombatRules.getDamageAfterAbsorb, with the attacking weapon's armor effectiveness.
    fn afterArmor(self: *PlayerDamage, slot: usize, source: Source, amount: f32) !f32 {
        const armor: f32 = @floatFromInt(@as(i32, @intFromFloat(@floor(try self.deps.attributes.value(slot, "minecraft:armor")))));
        const toughness: f32 = @floatCast(try self.deps.attributes.value(slot, "minecraft:armor_toughness"));
        const absorbed = std.math.clamp(armor - amount / (2.0 + toughness / 4.0), armor * 0.2, 20.0);
        var effectiveness = absorbed / 25.0;
        if (source.attack) |attack| if (source.weapon) |weapon| {
            effectiveness = std.math.clamp(try attack.armorEffectiveness(weapon, self.player_type, effectiveness), 0, 1);
        };
        return amount * (1.0 - effectiveness);
    }

    /// LivingEntity.getDamageAfterMagicAbsorb without effects: the damage_protection of what the
    /// player wears.
    fn afterProtection(self: *PlayerDamage, slot: usize, source: Source, flags: Flags, amount: f32) !f32 {
        if (flags.bypasses_effects) return amount;
        if (amount <= 0) return 0;
        if (flags.bypasses_enchantments) return amount;
        const player = &self.deps.players.records[slot];
        const registry = self.deps.client.client.get("minecraft:damage_type") orelse return error.MissingDamageRegistry;
        const type_id = registry.id(DamageTypes.name(source.type)) orelse return error.UnknownDamageType;
        var protection: f32 = 0;
        for (armor_slots) |index| {
            const stack = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = index })).stack orelse continue;
            const pinned = try self.deps.items.acquire(stack);
            defer pinned.release();
            self.scratch.reset();
            protection = try self.deps.enchantments.effects.modifyFloat(.{
                .item = pinned.view,
                .slot = @intCast(index - 3),
                .amount = protection,
                .channel = .damage_protection,
                .random = self.random.random(),
                .player = player.uuid,
                .actor = player,
                .location = .{ .world = player.world, .position = player.position },
                .scratch = &self.scratch,
                .item_tags = &self.deps.items.deps.definitions.tags,
                .damage_source = .{ .registry = registry, .id = type_id },
            });
        }
        if (protection <= 0) return amount;
        return amount * (1 - std.math.clamp(protection, 0, 20) / 25);
    }

    /// LivingEntity.doHurtEquipment for the armor: each piece that wears when hurt loses a
    /// quarter of the damage, at least one.
    fn wearArmor(self: *PlayerDamage, slot: usize, flags: Flags, amount: f32) !void {
        if (amount <= 0) return;
        const player = &self.deps.players.records[slot];
        if (self.deps.player_states.of(player).gamemode == .creative) return;
        const wear: i32 = @intFromFloat(@max(1.0, amount / 4.0));
        var changed = false;
        for (armor_slots) |index| {
            const at: inventories.Slot = .{ .owner = player.uuid, .index = index };
            const held = try self.deps.inventories.get(at);
            const stack = held.stack orelse continue;
            const kind = try self.deps.items.kind(stack);
            // Equippable.damageOnHurt: false of the elytra alone among what a player wears.
            if (kind == self.elytra or self.deps.items.deps.definitions.properties[kind].equipment != 10 - index) continue;
            // DamageResistant: netherite shrugs off fire.
            if (flags.fire and resistsFire(kind)) continue;
            self.scratch.reset();
            const worn = try self.deps.durability.wear(stack, .{ .amount = wear, .slot = @intCast(index - 3), .actor = player, .random = self.random.random(), .scratch = &self.scratch });
            if (std.meta.eql(worn, held.stack)) continue;
            const committed = try self.deps.inventories.set(at, held.revision, worn);
            assert(committed);
            changed = true;
        }
        if (changed) self.deps.menus.changed(slot);
    }

    /// LivingEntity.hurtServer's response to a full hit: the damage event, the hurt mark, and
    /// knockback from where the damage came, with the tilt that shows it.
    fn react(self: *PlayerDamage, slot: usize, source: Source, flags: Flags, blocked: f32, dealt: f32) !void {
        const player = &self.deps.players.records[slot];
        const living = self.livingOf(slot);
        if (blocked > 0) {
            // BlocksAttacks.onBlocked: the block's sound instead of the damage event.
            const use = self.deps.using.of(slot);
            const blocks = if (use) |value| game_data.physics.itemBlocksAttacks(value.kind) else null;
            if (blocks) |item| if (item.block_sound.len > 0) self.queueSound(slot, item.block_sound, 1.0, self.shieldPitch());
        } else {
            // Each hit sends its event, as vanilla's sendEntityDamage does: one already waiting
            // goes first, with all that came with it.
            if (living.event_count == living.events.len) self.flush(slot, living);
            living.events[living.event_count] = .{ .damage = .{ .id = entity_effects.playerId(slot), .type_id = self.deps.damage_types.idOf(source.type), .cause = source.cause_id, .direct = source.direct_id } };
            living.event_count += 1;
        }
        if (!flags.no_impact and (blocked <= 0 or dealt > 0)) living.marked = true;
        if (flags.no_knockback) return;
        var dx: f64 = 0;
        var dz: f64 = 0;
        if (source.knockback) |direction| {
            dx = -direction[0];
            dz = -direction[1];
        } else if (source.position) |position| {
            dx = position[0] - player.position.x;
            dz = position[2] - player.position.z;
        }
        try self.knockback(slot, 0.4, dx, dz);
        // A blocked hit pushes without hurting, so the client is told nothing more.
        if (blocked > 0) {
            if (blocked > 0 and dealt <= 0) living.marked = false;
            return;
        }
        // LivingEntity.indicateDamage: the tilt, from where the hit came relative to the look.
        living.tilt = @floatCast(std.math.atan2(dz, dx) * 57.2957763671875 - @as(f64, player.rotation.yaw));
    }

    /// LivingEntity.knockback: half the motion stays, and the push away from the direction
    /// comes on, and up while on the ground. A direction too short to normalize turns random.
    pub fn knockback(self: *PlayerDamage, slot: usize, strength_in: f64, x_in: f64, z_in: f64) !void {
        const resistance = try self.deps.attributes.value(slot, "minecraft:knockback_resistance");
        const strength = strength_in * (1.0 - resistance);
        if (strength <= 0) return;
        const living = self.livingOf(slot);
        var x = x_in;
        var z = z_in;
        const random = self.random.random();
        while (x * x + z * z < @as(f64, @as(f32, 1.0e-5))) {
            x = (random.float(f64) - random.float(f64)) * 0.01;
            z = (random.float(f64) - random.float(f64)) * 0.01;
        }
        const length = @sqrt(x * x + z * z);
        const velocity = living.motion;
        const on_ground = self.deps.players.records[slot].on_ground;
        living.motion = .{
            velocity[0] / 2.0 - x / length * strength,
            if (on_ground) @min(0.4, velocity[1] / 2.0 + strength) else velocity[1],
            velocity[2] / 2.0 - z / length * strength,
        };
        living.marked = true;
    }

    /// Entity.setDeltaMovement for a player, as its client is told at the tick's end.
    pub fn setMotion(self: *PlayerDamage, slot: usize, velocity: [3]f64) !void {
        for (velocity) |axis| if (!std.math.isFinite(axis)) return error.InvalidPush;
        const living = self.livingOf(slot);
        living.motion = velocity;
        living.marked = true;
    }

    /// Entity.push for a player: motion added, which its client takes at the tick's end.
    pub fn push(self: *PlayerDamage, slot: usize, velocity: [3]f64) !void {
        for (velocity) |axis| if (!std.math.isFinite(axis)) return error.InvalidPush;
        const living = self.livingOf(slot);
        for (&living.motion, velocity) |*axis, added| axis.* += added;
        living.marked = true;
    }

    /// LivingEntity.die for a player: the death sound and event. The client shows its death
    /// screen as its health reaches zero.
    fn die(self: *PlayerDamage, slot: usize) void {
        const player = &self.deps.players.records[slot];
        const living = self.livingOf(slot);
        self.queueSound(slot, "minecraft:entity.player.death", 1, self.voicePitch());
        living.died = true;
        living.fire_ticks = 0;
        if (player.flags.burning) {
            player.flags.burning = false;
            player.revision += 1;
        }
    }

    /// Entity.igniteForSeconds through LivingEntity.igniteForTicks.
    pub fn ignite(self: *PlayerDamage, slot: usize, seconds: f32) !void {
        assert(std.math.isFinite(seconds));
        const player = &self.deps.players.records[slot];
        const state = self.deps.player_states.of(player);
        if (state.health <= 0) return;
        const base: f64 = @floatFromInt(@as(i32, @intFromFloat(@floor(seconds * 20.0))));
        const ticks = std.math.lossyCast(i32, @ceil(base * try self.deps.attributes.value(slot, "minecraft:burning_time")));
        const living = self.livingOf(slot);
        if (living.fire_ticks >= ticks) return;
        living.fire_ticks = ticks;
        if (!player.flags.burning) {
            player.flags.burning = true;
            player.revision += 1;
        }
    }

    /// Ticks invulnerability down, burns, and sends what this tick's hits showed.
    pub fn tick(self: *PlayerDamage) !void {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (player.handle == null or player.stage != .ready) continue;
            const living = self.livingOf(slot);
            if (living.invulnerable_time > 0) living.invulnerable_time -= 1;
            if (living.fire_ticks > 0) try self.burn(slot);
            self.flush(slot, living);
            // The health bar follows whatever changed the health.
            const state = self.deps.player_states.of(player);
            if (player.inWorld() and state.health != state.health_sent and self.deps.player_states.sendHealth(player, state.health)) state.health_sent = state.health;
        }
    }

    /// Sends a player's hits of this tick: the damage event and motion to it and those who see
    /// it, the tilt to it alone, the sound to everyone near, and a death's event to the rest.
    fn flush(self: *PlayerDamage, slot: usize, living: *Living) void {
        if (living.event_count == 0 and !living.marked and living.tilt == null and living.sound_count == 0) return;
        const player = &self.deps.players.records[slot];
        const network_id = entity_effects.playerId(slot);
        const viewers = self.deps.replication.viewers(slot);
        for (living.events[0..living.event_count]) |event| self.entity.send(viewers, slot, event);
        if (living.marked) self.entity.send(viewers, slot, .{ .velocity = .{ .id = network_id, .velocity = living.motion } });
        if (living.tilt) |yaw| self.entity.toPlayer(slot, .{ .hurt_animation = .{ .id = network_id, .yaw = yaw } });
        for (living.sounds[0..living.sound_count]) |queued| self.effects.sound(player.world, player.position, queued.name, .players, queued.volume, queued.pitch, queued.seed, null);
        if (living.died) self.entity.send(viewers, null, .{ .status = .{ .id = network_id, .status = 3 } });
        living.* = .{ .generation = living.generation, .life = living.life, .invulnerable_time = living.invulnerable_time, .last_hurt = living.last_hurt, .fire_ticks = living.fire_ticks };
    }

    /// Entity.baseTick's fire: a point of damage each second, out in water or rain.
    fn burn(self: *PlayerDamage, slot: usize) !void {
        const player = &self.deps.players.records[slot];
        const living = self.livingOf(slot);
        const gamemode = self.deps.player_states.of(player).gamemode;
        if (gamemode == .creative or gamemode == .spectator) living.fire_ticks = 0;
        if (living.fire_ticks > 0) {
            if (@rem(living.fire_ticks, 20) == 0) _ = try self.hurt(slot, .{ .type = .on_fire }, 1);
            living.fire_ticks -= 1;
        }
        if (living.fire_ticks <= 0 and player.flags.burning) {
            player.flags.burning = false;
            player.revision += 1;
        }
    }

    /// A sound at a player, for everyone near and itself too, once the tick sends it. More than
    /// there is room for in one tick send what came before them first, in order: none is lost.
    fn queueSound(self: *PlayerDamage, slot: usize, name: []const u8, volume: f32, pitch: f32) void {
        const living = self.livingOf(slot);
        if (living.sound_count == living.sounds.len) self.flush(slot, living);
        living.sounds[living.sound_count] = .{ .name = name, .volume = volume, .pitch = pitch, .seed = @bitCast(self.random.next()) };
        living.sound_count += 1;
    }

    /// LivingEntity.getVoicePitch for an adult.
    fn voicePitch(self: *PlayerDamage) f32 {
        const random = self.random.random();
        return (random.float(f32) - random.float(f32)) * 0.2 + 1.0;
    }

    /// The pitch of a shield's sounds.
    fn shieldPitch(self: *PlayerDamage) f32 {
        return 0.8 + self.random.random().float(f32) * 0.4;
    }
};

const Sound = struct { name: []const u8, volume: f32, pitch: f32, seed: i64 };

/// Whether an item's damage_resistant component keeps fire off it, as netherite's does.
fn resistsFire(kind: u32) bool {
    const tag = game_data.physics.itemResistance(kind) orelse return false;
    return std.mem.eql(u8, tag, "minecraft:is_fire");
}

/// Player.getHurtSound: the sound of the damage type's effects.
fn hurtSound(damage_type: DamageType) []const u8 {
    return switch (damage_type) {
        .on_fire, .in_fire, .lava, .hot_floor, .campfire => "minecraft:entity.player.hurt_on_fire",
        .drown => "minecraft:entity.player.hurt_drown",
        .sweet_berry_bush => "minecraft:entity.player.hurt_sweet_berry_bush",
        .freeze => "minecraft:entity.player.hurt_freeze",
        .thorns => "minecraft:enchant.thorns.hit",
        else => "minecraft:entity.player.hurt",
    };
}
