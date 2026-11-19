//! Players acting on mobs, from ServerboundInteractPacket as ServerGamePacketListenerImpl
//! handles it: attacks go through Player.attack, and uses through Mob.interact, where cows are
//! milked with buckets, fed their food to fall in love or grow, and given spawn eggs for calves.

const std = @import("std");
const game_data = @import("game_data");
const sessions = @import("sessions");
const inventories = @import("inventories");
const wire = @import("wire_1_21_5");
const modern_wire = @import("wire_26_1");
const protocols = @import("minecraft_packets").protocols;
const Input = @import("players").input.Input;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const Items = @import("vanilla_items").items.Items;
const FallDamage = @import("vanilla_survival").fall_damage.FallDamage;
const world_effects = @import("vanilla_blocks").world_effects;
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
const mob_state = @import("mob.zig");
const mob_replication = @import("mob_replication.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const registry = game_data.registry;
const assert = std.debug.assert;

pub const MobInteraction = struct {
    pub const id = "minecraft:mob_interaction";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        input: *Input,
        players: *Players,
        player_states: *PlayerStates,
        mobs: *Mobs,
        inventories: *inventories.Inventories,
        items: *Items,
        menus: *PlayerInventory,
        attributes: *EquipmentAttributes,
        falls: *FallDamage,
    };

    /// Player.attackStrengthTicker, by player slot: ticks since the last attack or change of
    /// held item, and that item, to notice the change.
    const Attack = struct { generation: u32 = 0, ticker: i32 = 0, held: ?u32 = null };

    deps: Dependencies,
    attacks: []Attack,
    effects: world_effects.Effects,
    sound_seeds: std.Random.DefaultPrng,
    bucket: u32,
    milk_bucket: u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*MobInteraction {
        const self = try allocator.create(MobInteraction);
        const attacks = try allocator.alloc(Attack, deps.players.records.len);
        @memset(attacks, .{});
        self.* = .{
            .deps = deps,
            .attacks = attacks,
            .effects = try .init(allocator, deps.players),
            .sound_seeds = .init(0x696e7465726163),
            .bucket = @intCast(registry.itemId("minecraft:bucket").?),
            .milk_bucket = @intCast(registry.itemId("minecraft:milk_bucket").?),
        };
        try deps.input.on(.use_entity, self, .{ onUse, onUseModern });
        inline for (protocols.implementations) |Version| {
            if (@hasField(Version.Protocol.play.toServer.PacketName, "attack")) try deps.input.onVersion(Version, .attack, self, onAttack);
        }
        return self;
    }

    /// Player.tick's attack strength: it climbs every tick and starts over when the held item
    /// changes.
    pub fn tick(self: *MobInteraction) !void {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            const handle = player.handle orelse continue;
            const strength = &self.attacks[slot];
            if (strength.generation != handle.generation) strength.* = .{ .generation = handle.generation };
            strength.ticker += 1;
            const held = try self.heldKind(slot, .main);
            if (held != strength.held) {
                strength.held = held;
                strength.ticker = 0;
            }
        }
    }

    const Hand = enum { main, off };

    fn heldSlot(self: *MobInteraction, slot: usize, hand: Hand) inventories.Slot {
        const player = &self.deps.players.records[slot];
        const state = self.deps.player_states.of(player);
        return .{ .owner = player.uuid, .index = if (hand == .off) 45 else 36 + @as(u16, state.selected_slot) };
    }

    fn heldKind(self: *MobInteraction, slot: usize, hand: Hand) !?u32 {
        const stack = (try self.deps.inventories.get(self.heldSlot(slot, hand))).stack orelse return null;
        const pinned = try self.deps.items.acquire(stack);
        defer pinned.release();
        return pinned.view.kind;
    }

    fn onUse(self: *MobInteraction, handle: sessions.Handle, packet: wire.play.toServer.packet_use_entity.Reader) !void {
        const target, const a = try packet.target();
        const mouse, const b = try a.mouse();
        if (mouse < 0 or mouse > 2) return error.InvalidPacket;
        var x_field = try b.x();
        const after_x = if (mouse == 2) blk: {
            _, const done = try (try x_field.begin()).case_2();
            break :blk try x_field.advance(done);
        } else blk: {
            _, const done = try (try x_field.begin()).case_default();
            break :blk try x_field.advance(done);
        };
        var y_field = try after_x.y();
        const after_y = if (mouse == 2) blk: {
            _, const done = try (try y_field.begin()).case_2();
            break :blk try y_field.advance(done);
        } else blk: {
            _, const done = try (try y_field.begin()).case_default();
            break :blk try y_field.advance(done);
        };
        var z_field = try after_y.z();
        const after_z = if (mouse == 2) blk: {
            _, const done = try (try z_field.begin()).case_2();
            break :blk try z_field.advance(done);
        } else blk: {
            _, const done = try (try z_field.begin()).case_default();
            break :blk try z_field.advance(done);
        };
        var hand_field = try after_z.hand();
        var hand: i32 = 0;
        const after_hand = switch (mouse) {
            0 => blk: {
                hand, const done = try (try hand_field.begin()).case_0();
                break :blk try hand_field.advance(done);
            },
            2 => blk: {
                hand, const done = try (try hand_field.begin()).case_2();
                break :blk try hand_field.advance(done);
            },
            else => blk: {
                _, const done = try (try hand_field.begin()).case_default();
                break :blk try hand_field.advance(done);
            },
        };
        _, const end = try after_hand.sneaking();
        try end.finish();
        try self.dispatch(handle, target, mouse, hand);
    }

    /// 26.1 split attacks out, and every use is an interaction at a point on the entity.
    fn onUseModern(self: *MobInteraction, handle: sessions.Handle, packet: modern_wire.play.toServer.packet_use_entity.Reader) !void {
        const target, const a = try packet.target();
        const hand, const b = try a.hand();
        _, const c = try b.location();
        _, const end = try c.sneaking();
        try end.finish();
        try self.dispatch(handle, target, 0, hand);
    }

    fn onAttack(self: *MobInteraction, handle: sessions.Handle, packet: modern_wire.play.toServer.packet_attack.Reader) !void {
        const target, const end = try packet.entityId();
        try end.finish();
        try self.dispatch(handle, target, 1, 0);
    }

    fn dispatch(self: *MobInteraction, handle: sessions.Handle, target: i32, mouse: i32, hand: i32) !void {
        if (hand < 0 or hand > 1) return error.InvalidPacket;
        const player = &self.deps.players.records[handle.index];
        if (player.stage != .ready) return;
        // Network ids of mobs are their negated entity ids.
        if (target >= 0) return;
        const mob = self.deps.mobs.get(@intCast(-@as(i64, target))) orelse return;
        if (mob.world != player.world or mob.removed) return;
        if (!try self.withinReach(handle.index, mob)) return;
        switch (mouse) {
            1 => try self.attack(handle.index, mob),
            // Entity.interactAt passes for mobs, so only the plain interaction acts.
            0 => try self.interact(handle.index, mob, if (hand == 1) .off else .main),
            else => {},
        }
    }

    /// Player.canInteractWithEntity with ServerGamePacketListenerImpl's three blocks of slack:
    /// the mob's box within the interaction range of the eyes.
    fn withinReach(self: *MobInteraction, slot: usize, mob: *const Mob) !bool {
        const player = &self.deps.players.records[slot];
        const range = try self.deps.attributes.value(slot, "minecraft:entity_interaction_range") + 3.0;
        const eye: [3]f64 = .{ player.position.x, player.position.y + (if (player.flags.sneaking) @as(f64, @as(f32, 1.27)) else @as(f64, @as(f32, 1.62))), player.position.z };
        const box = living.box(self.deps.mobs, mob);
        var squared: f64 = 0;
        for (0..3) |axis| {
            const distance = @max(box.min[axis] - eye[axis], 0, eye[axis] - box.max[axis]);
            squared += distance * distance;
        }
        return squared < range * range;
    }

    // Mob.interact.

    fn interact(self: *MobInteraction, slot: usize, mob: *Mob, hand: Hand) !void {
        if (!mob.alive()) return;
        const player = &self.deps.players.records[slot];
        const state = self.deps.player_states.of(player);
        if (state.gamemode == .spectator) return;
        const held = (try self.deps.inventories.get(self.heldSlot(slot, hand))).stack orelse return;
        const pinned = try self.deps.items.acquire(held);
        const kind = pinned.view.kind;
        pinned.release();
        // Mob.checkAndHandleImportantInteractions: a spawn egg of the mob's kind makes a calf.
        if (game_data.physics.spawnEgg(@intCast(kind))) |entity_type| {
            if (entity_type == self.deps.mobs.traits(mob.species).entity_type) {
                try self.offspringFromEgg(slot, mob, hand);
                return;
            }
        }
        // AbstractCow.mobInteract: a bucket fills with milk from a grown cow.
        if (kind == self.bucket and !mob.baby()) {
            self.playerSound(slot, "minecraft:entity.cow.milk");
            try self.exchange(slot, hand, self.milk_bucket);
            return;
        }
        // Animal.mobInteract.
        if (try self.deps.mobs.isFood(held)) {
            if (mob.age == 0 and mob.in_love <= 0) {
                try self.usePlayerItem(slot, hand);
                self.deps.mobs.setInLove(mob, player.uuid);
                return;
            }
            if (mob.baby()) {
                try self.usePlayerItem(slot, hand);
                self.deps.mobs.ageUp(mob, speedUpSecondsWhenFeeding(-mob.age), true);
                return;
            }
        }
    }

    /// AgeableMob.getSpeedUpSecondsWhenFeeding.
    fn speedUpSecondsWhenFeeding(ticks: i32) i32 {
        return mth.javaInt(@as(f32, @floatFromInt(@divTrunc(ticks, 20))) * 0.1);
    }

    /// SpawnEggItem.spawnOffspringFromSpawnEgg for a mob that can be a baby.
    fn offspringFromEgg(self: *MobInteraction, slot: usize, mob: *Mob, hand: Hand) !void {
        const mobs = self.deps.mobs;
        if (!mobs.canSpawn()) return;
        _ = try mobs.spawn(.{ .species = mob.species, .world = mob.world, .position = mob.position, .yaw = 0, .baby = true, .variant = mob.variant, .finalize = false });
        try self.usePlayerItem(slot, hand);
    }

    /// Animal.usePlayerItem: one of the held stack is used up, but by players with infinite
    /// materials.
    fn usePlayerItem(self: *MobInteraction, slot: usize, hand: Hand) !void {
        const player = &self.deps.players.records[slot];
        if (self.deps.player_states.of(player).gamemode == .creative) return;
        const held_slot = self.heldSlot(slot, hand);
        const held = try self.deps.inventories.get(held_slot);
        const stack = held.stack orelse return;
        const committed = try self.deps.inventories.set(held_slot, held.revision, if (stack.count > 1) .{ .item = stack.item, .count = stack.count - 1 } else null);
        assert(committed);
        self.deps.menus.changed(slot);
    }

    /// ItemUtils.createFilledResult: one of the held stack becomes the output, which in creative
    /// is added only if the inventory has none.
    fn exchange(self: *MobInteraction, slot: usize, hand: Hand, output: u32) !void {
        const player = &self.deps.players.records[slot];
        const name = registry.item_names[output];
        if (self.deps.player_states.of(player).gamemode == .creative) {
            _ = try self.deps.menus.give(slot, name, 1);
            return;
        }
        const held_slot = self.heldSlot(slot, hand);
        const held = try self.deps.inventories.get(held_slot);
        const stack = held.stack orelse return;
        if (stack.count == 1) {
            const committed = try self.deps.inventories.set(held_slot, held.revision, .{ .item = try self.deps.items.define(name), .count = 1 });
            assert(committed);
            self.deps.menus.changed(slot);
            return;
        }
        const committed = try self.deps.inventories.set(held_slot, held.revision, .{ .item = stack.item, .count = stack.count - 1 });
        assert(committed);
        self.deps.menus.changed(slot);
        if (try self.deps.menus.give(slot, name, 1)) return;
        _ = try self.deps.menus.dropMany(player.*, &.{.{ .item = try self.deps.items.define(name), .count = 1 }});
    }

    /// Player.playSound: where the player is, for everyone but them.
    fn playerSound(self: *MobInteraction, slot: usize, name: []const u8) void {
        const player = &self.deps.players.records[slot];
        self.effects.sound(player.world, player.position, name, .players, 1, 1, @bitCast(self.sound_seeds.next()), slot);
    }

    // Player.attack.

    fn attack(self: *MobInteraction, slot: usize, mob: *Mob) !void {
        const player = &self.deps.players.records[slot];
        const state = self.deps.player_states.of(player);
        if (state.gamemode == .spectator or state.health <= 0) return;
        var damage: f32 = @floatCast(try self.deps.attributes.value(slot, "minecraft:attack_damage"));
        const speed = try self.deps.attributes.value(slot, "minecraft:attack_speed");
        // Player.getAttackStrengthScale(0.5).
        const delay: f32 = @floatCast(1.0 / speed * 20.0);
        const scale = mth.clamp((@as(f32, @floatFromInt(self.attacks[slot].ticker)) + 0.5) / delay, 0, 1);
        damage *= 0.2 + scale * scale * 0.8;
        self.attacks[slot].ticker = 0;
        if (damage <= 0) return;
        const strong = scale > 0.9;
        const knockback_hit = player.flags.sprinting and strong;
        if (knockback_hit) self.playerSoundAll(slot, "minecraft:entity.player.attack.knockback");
        // Player.attack's critical hit, falling and not on the ground or sprinting.
        const critical = strong and self.falling(slot) and !player.on_ground and !player.flags.sprinting;
        if (critical) damage *= 1.5;
        const hurt = try self.deps.mobs.hurt(mob, .{ .type = .player_attack, .attacker = @intCast(slot), .source = .{ player.position.x, player.position.y, player.position.z } }, damage);
        if (!hurt) {
            self.playerSoundAll(slot, "minecraft:entity.player.attack.nodamage");
            return;
        }
        const knockback: f32 = @as(f32, @floatCast(try self.deps.attributes.value(slot, "minecraft:attack_knockback"))) + (if (knockback_hit) @as(f32, 1.0) else 0.0);
        if (knockback > 0) {
            const yaw = player.rotation.yaw * (std.math.pi / 180.0);
            self.deps.mobs.knockback(mob, knockback * 0.5, mth.sin(yaw), -mth.cos(yaw));
        }
        if (critical) {
            self.playerSoundAll(slot, "minecraft:entity.player.attack.crit");
        } else {
            self.playerSoundAll(slot, if (strong) "minecraft:entity.player.attack.strong" else "minecraft:entity.player.attack.weak");
        }
    }

    fn falling(self: *MobInteraction, slot: usize) bool {
        return fallingDistance(self.deps.falls, slot) > 0;
    }

    /// Level.playSound with no player: everyone nearby hears it, the attacker too.
    fn playerSoundAll(self: *MobInteraction, slot: usize, name: []const u8) void {
        const player = &self.deps.players.records[slot];
        self.effects.sound(player.world, player.position, name, .players, 1, 1, @bitCast(self.sound_seeds.next()), null);
    }
};

fn fallingDistance(falls: *const FallDamage, slot: usize) f64 {
    return falls.falls[slot].distance;
}
