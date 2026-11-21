//! EnchantmentHelper's attack hooks for one attack: modifyDamage, modifyKnockback,
//! modifyArmorEffectiveness and doPostAttackEffects. The registries and the damage source an
//! attack shares are looked up once, when it starts; each hook then reads the item in place.

const std = @import("std");
const Player = @import("players").player_state.Player;
const Registries = @import("vanilla_content").content_registries.Registries;
const Tags = @import("vanilla_content").content_tags.Tags;
const effects = @import("enchantment_effects.zig");
const item_data = @import("item_data.zig");

const assert = std.debug.assert;

pub const Attack = struct {
    effects: *const effects.Effects,
    item_tags: *const Tags,
    entity_types: *const Registries.Registry,
    damage_source: effects.DamageSource,
    /// The player the attack is from, for effects that read where or who it is.
    attacker: *const Player,
    /// What dealt the damage, by entity type: the attacker, or its projectile.
    direct_type: u32,
    /// Whether the attacker dealt the damage itself.
    direct: bool,
    random: std.Random,
    scratch: *std.heap.FixedBufferAllocator,

    pub const Start = struct {
        effects: *const effects.Effects,
        item_tags: *const Tags,
        registries: *const Registries,
        damage_type: []const u8,
        attacker: *const Player,
        direct_type: u32,
        direct: bool = true,
        random: std.Random,
        scratch: *std.heap.FixedBufferAllocator,
    };

    pub fn start(begin: Start) !Attack {
        const damage_types = begin.registries.get("minecraft:damage_type") orelse return error.MissingDamageRegistry;
        const entity_types = begin.registries.get("minecraft:entity_type") orelse return error.MissingEntityTypeRegistry;
        assert(begin.direct_type < entity_types.entries.len);
        return .{
            .effects = begin.effects,
            .item_tags = begin.item_tags,
            .entity_types = entity_types,
            .damage_source = .{ .registry = damage_types, .id = damage_types.id(begin.damage_type) orelse return error.UnknownDamageType },
            .attacker = begin.attacker,
            .direct_type = begin.direct_type,
            .direct = begin.direct,
            .random = begin.random,
            .scratch = begin.scratch,
        };
    }

    /// EnchantmentHelper.modifyDamage: every enchantment on the weapon, whatever its slots.
    pub fn damage(self: *const Attack, weapon: ?item_data.View, target_type: u32, amount: f32) !f32 {
        return self.modify(weapon, .damage, target_type, amount);
    }

    /// EnchantmentHelper.modifyKnockback.
    pub fn knockback(self: *const Attack, weapon: ?item_data.View, target_type: u32, amount: f32) !f32 {
        return self.modify(weapon, .knockback, target_type, amount);
    }

    /// EnchantmentHelper.modifyArmorEffectiveness.
    pub fn armorEffectiveness(self: *const Attack, weapon: ?item_data.View, target_type: u32, amount: f32) !f32 {
        return self.modify(weapon, .armor_effectiveness, target_type, amount);
    }

    /// EnchantmentHelper.modifyFallBasedDamage, per block fallen.
    pub fn smashDamagePerBlock(self: *const Attack, weapon: ?item_data.View, target_type: u32) !f32 {
        return self.modify(weapon, .smash_damage_per_fallen_block, target_type, 0);
    }

    /// Enchantment.doPostAttack for one item: what its post_attack effects for the holder in
    /// `role` do, their randomness rolled, the target being `victim_type`. `slot` is where the
    /// item is worn, as the enchantment's slots must allow.
    pub fn postAttack(self: *const Attack, item: item_data.View, slot: u3, role: effects.PostAttack.Holder, victim_type: u32, output: []effects.Consequence) !usize {
        var specific = self.request(item, .damage, victim_type, 0);
        specific.slot = slot;
        specific.any_slot = false;
        return self.effects.postAttack(specific, role, output);
    }

    fn modify(self: *const Attack, weapon: ?item_data.View, channel: effects.Channel, target_type: u32, amount: f32) !f32 {
        assert(std.math.isFinite(amount));
        const item = weapon orelse return amount;
        return self.effects.modifyFloat(self.request(item, channel, target_type, amount));
    }

    /// The attack hooks count every enchantment on the item, whatever its slots, as
    /// runIterationOnItem walks it.
    fn request(self: *const Attack, item: item_data.View, channel: effects.Channel, target_type: u32, amount: f32) effects.Request {
        assert(target_type < self.entity_types.entries.len);
        return .{
            .item = item,
            .slot = 0,
            .any_slot = true,
            .amount = amount,
            .channel = channel,
            .random = self.random,
            .player = self.attacker.uuid,
            .actor = self.attacker,
            .location = .{ .world = self.attacker.world, .position = self.attacker.position },
            .scratch = self.scratch,
            .item_tags = self.item_tags,
            .damage_source = self.damage_source,
            .entity_types = self.entity_types,
            .target_type = target_type,
            .direct_type = self.direct_type,
            .direct = self.direct,
        };
    }
};
