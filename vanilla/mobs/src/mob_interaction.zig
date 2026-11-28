//! Players acting on mobs and each other, from ServerboundInteractPacket as
//! ServerGamePacketListenerImpl handles it: attacks go to Melee, and uses through Mob.interact,
//! where a mob's species acts first, as a cow gives milk, then animals are fed their food to fall
//! in love or grow, and given spawn eggs for young, and last an item may act on the mob.

const std = @import("std");
const game_data = @import("game_data");
const entities = @import("entities");
const sessions = @import("sessions");
const inventories = @import("inventories");
const wire = @import("wire_1_21_5");
const modern_wire = @import("wire_26_1");
const protocols = @import("minecraft_packets").protocols;
const Input = @import("players").input.Input;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const Items = @import("vanilla_items").items.Items;
const Durability = @import("vanilla_items").item_properties.Durability;
const world_effects = @import("vanilla_blocks").world_effects;
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;
const body = @import("vanilla_bodies").body;
const Melee = @import("melee.zig").Melee;
const Boats = @import("boats.zig").Boats;
const senses = @import("senses.zig");
const Player = @import("players").player_state.Player;
const boat_module = @import("boat.zig");

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
        world_border: *WorldBorder,
        mobs: *Mobs,
        inventories: *inventories.Inventories,
        items: *Items,
        menus: *PlayerInventory,
        attributes: *EquipmentAttributes,
        melee: *Melee,
        durability: *Durability,
    };

    deps: Dependencies,
    effects: world_effects.Effects,
    sound_seeds: std.Random.DefaultPrng,
    /// The random tools wear by, as the level's would draw for unbreaking.
    random: std.Random.DefaultPrng,
    scratch: std.heap.FixedBufferAllocator,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*MobInteraction {
        const self = try allocator.create(MobInteraction);
        self.* = .{
            .deps = deps,
            .effects = try .init(allocator, deps.players),
            .sound_seeds = .init(0x696e7465726163),
            .random = .init(0x7368656172),
            .scratch = .init(try allocator.alloc(u8, 16 * 1024)),
        };
        try deps.input.on(.use_entity, self, .{ onUse, onUseModern });
        inline for (protocols.implementations) |Version| {
            if (@hasField(Version.Protocol.play.toServer.PacketName, "attack")) try deps.input.onVersion(Version, .attack, self, onAttack);
        }
        return self;
    }

    pub const Hand = enum { main, off };

    fn heldSlot(self: *MobInteraction, slot: usize, hand: Hand) inventories.Slot {
        const player = &self.deps.players.records[slot];
        const state = self.deps.player_states.of(player);
        return .{ .owner = player.uuid, .index = if (hand == .off) 45 else 36 + @as(u16, state.selected_slot) };
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
        // Players' network ids are their slots plus one; other entities' come after.
        if (target <= 0) return;
        if (target <= entities.Entities.player_ids) return self.dispatchPlayer(handle.index, @intCast(target - 1), mouse);
        const entity = self.deps.mobs.deps.entities.entityOfNetwork(target) orelse return;
        if (self.deps.mobs.boats) |boats| if (boats.boats.slotOf(entity)) |slot| return self.dispatchBoat(handle.index, boats, slot, mouse);
        const mob = (try self.deps.mobs.get(entity)) orelse return;
        if (mob.motion.world != player.world or mob.entity.removed) return;
        // ServerGamePacketListenerImpl.handleInteract: nothing outside the border is reached.
        if (!self.deps.world_border.containsBlock(player.world, mth.floor(mob.motion.position[0]), mth.floor(mob.motion.position[2]))) return;
        if (!try self.withinReach(handle.index, living.box(self.deps.mobs, mob))) return;
        switch (mouse) {
            1 => try self.deps.melee.attack(handle.index, .{ .mob = mob }),
            // Entity.interactAt passes for mobs, so only the plain interaction acts.
            0 => try self.interact(handle.index, mob, if (hand == 1) .off else .main),
            else => {},
        }
    }

    /// An interaction with a boat: an attack, as Player.attack takes it of what is not living, or
    /// its use, AbstractBoat.interact, which boards it.
    fn dispatchBoat(self: *MobInteraction, slot: usize, boats: *Boats, boat: u32, mouse: i32) !void {
        const player = &self.deps.players.records[slot];
        if (!boats.solid(boat)) return;
        const state = boats.deps.entities.body(boat).?;
        if (state.world != player.world) return;
        if (!self.deps.world_border.containsBlock(player.world, mth.floor(state.position[0]), mth.floor(state.position[2]))) return;
        if (!try self.withinReach(slot, boat_module.boxAt(state.position))) return;
        switch (mouse) {
            1 => try self.deps.melee.attack(slot, .{ .boat = boat }),
            0 => try boats.interact(slot, boat),
            else => {},
        }
    }

    /// An interaction with another player: an attack, as ServerPlayer.attack takes it. A player
    /// cannot hit itself or someone in another world, and nothing uses a player.
    fn dispatchPlayer(self: *MobInteraction, slot: usize, victim: usize, mouse: i32) !void {
        if (mouse != 1 or victim == slot or victim >= self.deps.players.records.len) return;
        const other = &self.deps.players.records[victim];
        const player = &self.deps.players.records[slot];
        if (other.handle == null or other.stage != .ready or other.world != player.world) return;
        const at = other.position;
        if (!self.deps.world_border.containsBlock(player.world, mth.floor(at.x), mth.floor(at.z))) return;
        const height: f64 = if (other.flags.sneaking) 1.5 else 1.8;
        if (!try self.withinReach(slot, .{ .min = .{ at.x - 0.3, at.y, at.z - 0.3 }, .max = .{ at.x + 0.3, at.y + height, at.z + 0.3 } })) return;
        try self.deps.melee.attack(slot, .{ .player = victim });
    }

    /// ServerGamePacketListenerImpl's three blocks of slack over the interaction range.
    fn withinReach(self: *MobInteraction, slot: usize, box: body.Box) !bool {
        return canInteractWithEntity(self.deps.attributes, &self.deps.players.records[slot], slot, box, 3.0);
    }

    // Mob.interact.

    fn interact(self: *MobInteraction, slot: usize, mob: Mob, hand: Hand) !void {
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
            if (entity_type == self.deps.mobs.traits(mob.entity.species).entity_type) {
                try self.offspringFromEgg(slot, mob, hand);
                return;
            }
        }
        const hooks = self.deps.mobs.traits(mob.entity.species).definition.hooks;
        const use: Use = .{ .interaction = self, .slot = slot, .hand = hand, .mob = mob, .held = held, .kind = kind };
        // Mob.mobInteract as the species overrides it, before Animal's.
        if (hooks.interact) |interact_hook| if (try interact_hook(hooks.context, &use)) return;
        // Animal.mobInteract.
        if (try self.deps.mobs.isFood(held, mob.entity.species)) {
            if (mob.idle.age == 0 and mob.inLove() <= 0) {
                try self.usePlayerItem(slot, hand);
                try self.deps.mobs.setInLove(mob, player.uuid);
                return;
            }
            if (mob.baby()) {
                try self.usePlayerItem(slot, hand);
                try self.deps.mobs.ageUp(mob, speedUpSecondsWhenFeeding(-mob.idle.age), true);
                return;
            }
        }
        // Player.interactOn: the mob passed the use on, so the item may act on it, as a dye on a
        // sheep.
        if (hooks.use_item) |use_item| _ = try use_item(hooks.context, &use);
    }

    /// ItemStack.hurtAndBreak by one, for the tool in a hand, but in creative.
    pub fn wearHeld(self: *MobInteraction, slot: usize, hand: Hand) !void {
        const player = &self.deps.players.records[slot];
        if (self.deps.player_states.of(player).gamemode == .creative) return;
        const held_slot = self.heldSlot(slot, hand);
        const held = try self.deps.inventories.get(held_slot);
        const stack = held.stack orelse return;
        self.scratch.reset();
        const worn = try self.deps.durability.wear(stack, .{ .amount = 1, .slot = if (hand == .off) 1 else 0, .actor = player, .random = self.random.random(), .scratch = &self.scratch });
        if (std.meta.eql(worn, held.stack)) return;
        const committed = try self.deps.inventories.set(held_slot, held.revision, worn);
        assert(committed);
        self.deps.menus.changed(slot);
    }

    /// AgeableMob.getSpeedUpSecondsWhenFeeding.
    fn speedUpSecondsWhenFeeding(ticks: i32) i32 {
        return mth.javaInt(@as(f32, @floatFromInt(@divTrunc(ticks, 20))) * 0.1);
    }

    /// SpawnEggItem.spawnOffspringFromSpawnEgg for a mob that can be a baby.
    fn offspringFromEgg(self: *MobInteraction, slot: usize, mob: Mob, hand: Hand) !void {
        const mobs = self.deps.mobs;
        _ = try mobs.spawnOffspring(mob, mob);
        try self.usePlayerItem(slot, hand);
    }

    /// Animal.usePlayerItem: one of the held stack is used up, but by players with infinite
    /// materials.
    pub fn usePlayerItem(self: *MobInteraction, slot: usize, hand: Hand) !void {
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
    pub fn exchange(self: *MobInteraction, slot: usize, hand: Hand, output: u32) !void {
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
    pub fn playerSound(self: *MobInteraction, slot: usize, name: []const u8) void {
        const player = &self.deps.players.records[slot];
        self.effects.sound(player.world, player.position, name, .players, 1, 1, @bitCast(self.sound_seeds.next()), slot);
    }
};

/// A player using what is in a hand on a mob, as a species' hooks see it, with what they may do.
pub const Use = struct {
    interaction: *MobInteraction,
    slot: usize,
    hand: MobInteraction.Hand,
    mob: Mob,
    held: inventories.Stack,
    /// The held item's kind.
    kind: u32,

    /// Level.playSound with the player and the mob: a sound that follows the mob, for everyone
    /// but the player, whose client plays it already.
    pub fn sound(self: *const Use, name: []const u8) void {
        const at = self.mob.motion.position;
        const interaction = self.interaction;
        const entity: i32 = @intCast(interaction.deps.mobs.givenId(self.mob));
        interaction.effects.entitySound(self.mob.motion.world, .{ .x = at[0], .y = at[1], .z = at[2] }, entity, name, .players, 1, 1, @bitCast(interaction.sound_seeds.next()), self.slot);
    }
};

/// Player.canInteractWithEntity: the entity's box within the player's interaction range of its
/// eyes, and `slack` more.
pub fn canInteractWithEntity(attributes: *EquipmentAttributes, player: *const Player, slot: usize, box: body.Box, slack: f64) !bool {
    const range = try attributes.value(slot, "minecraft:entity_interaction_range") + slack;
    const eye: [3]f64 = .{ player.position.x, player.position.y + senses.playerEyeHeight(player.flags.sneaking), player.position.z };
    var squared: f64 = 0;
    for (0..3) |axis| {
        const distance = @max(box.min[axis] - eye[axis], 0, eye[axis] - box.max[axis]);
        squared += distance * distance;
    }
    return squared < range * range;
}
