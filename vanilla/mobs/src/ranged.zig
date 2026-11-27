//! Bows and tridents, as BowItem and TridentItem use them: drawn or raised while the use lasts,
//! and on release an arrow flies with the draw's power, or the trident is thrown. Their
//! enchantments, from Power to Loyalty, come through the enchantment effects.

const std = @import("std");
const game_data = @import("game_data");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const Items = @import("vanilla_items").items.Items;
const item_data = @import("vanilla_items").item_data;
const item_actions = @import("vanilla_items").item_actions;
const ItemActions = item_actions.ItemActions;
const item_using = @import("vanilla_items").item_using;
const ItemUsing = item_using.ItemUsing;
const enchantment_effects = @import("vanilla_items").enchantment_effects;
const EnchantmentRegistry = @import("vanilla_items").enchantment_registry.EnchantmentRegistry;
const Durability = @import("vanilla_items").item_properties.Durability;
const world_effects = @import("vanilla_blocks").world_effects;
const mth = @import("vanilla_bodies").mth;
const chunks = @import("chunks");
const PlayerDamage = @import("vanilla_survival").player_damage.PlayerDamage;
const projectiles = @import("projectiles.zig");
const Projectiles = projectiles.Projectiles;

const assert = std.debug.assert;
const registry = game_data.registry;

pub const Ranged = struct {
    pub const id = "minecraft:ranged";
    pub const Configuration = struct { seed: u64 = 0x626f77 };
    pub const Dependencies = struct {
        actions: *ItemActions,
        using: *ItemUsing,
        projectiles: *Projectiles,
        players: *Players,
        player_states: *PlayerStates,
        inventories: *inventories.Inventories,
        items: *Items,
        menus: *PlayerInventory,
        durability: *Durability,
        enchantments: *EnchantmentRegistry,
        damage: *PlayerDamage,
        chunks: *chunks.Chunks,
    };
    /// Item.getUseDuration of a bow and a trident.
    const use_duration = 72000;

    deps: Dependencies,
    chunk_client: chunks.Chunks.Client,
    effects: world_effects.Effects,
    random: std.Random.DefaultPrng,
    scratch: std.heap.FixedBufferAllocator,
    bow: u32,
    trident: u32,
    arrow: u32,
    spectral_arrow: u32,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Ranged {
        const self = try allocator.create(Ranged);
        self.* = .{
            .deps = deps,
            .chunk_client = try deps.chunks.simulation(1),
            .effects = try .init(allocator, deps.players),
            .random = .init(configuration.seed),
            .scratch = .init(try allocator.alloc(u8, 16 * 1024)),
            .bow = try item("minecraft:bow"),
            .trident = try item("minecraft:trident"),
            .arrow = try item("minecraft:arrow"),
            .spectral_arrow = try item("minecraft:spectral_arrow"),
        };
        try deps.actions.on(item_actions.Binding.bind(Ranged, self, use));
        try deps.using.onRelease(.{ .context = self, .call = released });
        return self;
    }

    fn item(name: []const u8) !u32 {
        return @intCast(registry.itemId(name) orelse return error.UnknownItem);
    }

    /// BowItem.use and TridentItem.use: drawing needs ammo, outside creative, and a trident
    /// must not be about to break.
    fn use(self: *Ranged, context: *const item_actions.Context) !item_actions.Result {
        const kind = context.item.kind;
        if (kind != self.bow and kind != self.trident) return .pass;
        const player = context.player;
        const slot = player.handle.?.index;
        const creative = self.deps.player_states.of(player).gamemode == .creative;
        if (kind == self.bow and !creative and try self.findAmmo(slot) == null) return .denied;
        if (kind == self.trident and try self.nextWearBreaks(context.item)) return .denied;
        // Riptide needs water about the holder.
        if (kind == self.trident and try self.modify(context.stack, .trident_spin_attack_strength, 0) > 0 and !try self.inWater(slot)) return .denied;
        self.deps.using.start(slot, if (context.hand == .off) .off else .main, context.stack, kind, use_duration);
        return .applied;
    }

    /// Whether one more point of wear breaks the item, as ItemStack.nextDamageWillBreak asks.
    fn nextWearBreaks(self: *Ranged, view: item_data.View) !bool {
        const maximum = self.deps.items.deps.definitions.properties[view.kind].durability;
        if (maximum == 0 or view.value(.unbreakable) != null) return false;
        const damage = if (view.value(.damage)) |value| (try @import("protocol_support").read_varint(value))[0] else 0;
        return damage + 1 >= maximum;
    }

    fn released(context: *anyopaque, slot: usize, use_: item_using.Use) !void {
        const self: *Ranged = @ptrCast(@alignCast(context));
        if (use_.kind == self.bow) try self.shoot(slot, use_);
        if (use_.kind == self.trident) try self.throw(slot, use_);
    }

    /// Where ammo is: the off hand, the main hand, then the inventory in its order.
    fn findAmmo(self: *Ranged, slot: usize) !?u16 {
        const player = &self.deps.players.records[slot];
        const selected = self.deps.player_states.of(player).selected_slot;
        var order: [38]u16 = undefined;
        order[0] = 45;
        order[1] = 36 + @as(u16, selected);
        for (0..36) |index| order[2 + index] = @intCast(if (index < 9) 36 + index else index);
        const tags = &self.deps.items.deps.definitions.tags;
        const arrows = tags.find("minecraft:arrows") orelse return null;
        for (order) |index| {
            const stack = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = index })).stack orelse continue;
            if (tags.contains(arrows, try self.deps.items.kind(stack))) return index;
        }
        return null;
    }

    /// BowItem.releaseUsing: the draw's power sets the arrow's speed, and a full draw makes it
    /// critical. Infinity, or creative, keeps the arrow.
    fn shoot(self: *Ranged, slot: usize, use_: item_using.Use) !void {
        const player = &self.deps.players.records[slot];
        const creative = self.deps.player_states.of(player).gamemode == .creative;
        const drawn: f32 = @as(f32, @floatFromInt(use_.ticks)) / 20.0;
        const power = @min((drawn * drawn + drawn * 2.0) / 3.0, 1.0);
        if (power < 0.1) return;
        const ammo_slot = try self.findAmmo(slot);
        if (ammo_slot == null and !creative) return;
        const owner = player.uuid;
        const ammo = if (ammo_slot) |index| try self.deps.inventories.get(.{ .owner = owner, .index = index }) else inventories.Contents{};
        const ammo_kind = if (ammo.stack) |stack| try self.deps.items.kind(stack) else self.arrow;
        const weapon = (try self.deps.inventories.get(self.handSlot(slot, use_.hand))).stack orelse return;
        const consumed = if (creative) 0 else try self.ammoUse(weapon, ammo_kind);
        const pickup: projectiles.Pickup = if (consumed == 0) .creative_only else .allowed;
        const fire = try self.spawnedFire(weapon);
        const stack: inventories.Stack = if (ammo.stack) |held| .{ .item = held.item, .count = 1 } else .{ .item = try self.deps.items.define("minecraft:arrow"), .count = 1 };
        try self.deps.projectiles.launch(.{
            .kind = if (ammo_kind == self.spectral_arrow) .spectral_arrow else .arrow,
            .world = player.world,
            .position = .{ player.position.x, player.position.y + 1.62 - 0.1, player.position.z },
            .velocity = self.withMovement(slot, self.deps.projectiles.aim(look(player.rotation), power * 3.0, 1.0)),
            .owner = slot,
            .stack = stack,
            .weapon = .{ .item = weapon.item, .count = 1 },
            .critical = power == 1.0,
            .pickup = pickup,
            .fire_ticks = fire,
        });
        if (consumed > 0) try self.consume(slot, ammo_slot.?, ammo, @intCast(consumed));
        try self.wear(slot, use_.hand, 1);
        const random = self.random.random();
        self.sound(player, "minecraft:entity.arrow.shoot", 1.0 / (random.float(f32) * 0.4 + 1.2) + power * 0.5);
    }

    /// TridentItem.releaseUsing: raised for half a second, it is thrown, or with Riptide it
    /// throws its holder instead.
    fn throw(self: *Ranged, slot: usize, use_: item_using.Use) !void {
        if (use_.ticks < 10) return;
        const player = &self.deps.players.records[slot];
        const creative = self.deps.player_states.of(player).gamemode == .creative;
        const at = self.handSlot(slot, use_.hand);
        const held = try self.deps.inventories.get(at);
        const stack = held.stack orelse return;
        const riptide = try self.modify(stack, .trident_spin_attack_strength, 0);
        if (riptide > 0) return self.launchHolder(slot, use_, riptide);
        // hurtWithoutBreaking, then the thrown trident takes the stack.
        self.scratch.reset();
        const worn = if (creative) stack else (try self.deps.durability.wear(stack, .{ .amount = 1, .slot = if (use_.hand == .off) 1 else 0, .actor = player, .random = self.random.random(), .scratch = &self.scratch })) orelse return;
        const loyalty = try self.modify(stack, .trident_return_acceleration, 0);
        const pinned = try self.deps.items.acquire(stack);
        const foil = pinned.view.value(.enchantments) != null;
        pinned.release();
        try self.deps.projectiles.launch(.{
            .kind = .trident,
            .world = player.world,
            .position = .{ player.position.x, player.position.y + 1.62 - 0.1, player.position.z },
            .velocity = self.withMovement(slot, self.deps.projectiles.aim(look(player.rotation), 2.5, 1.0)),
            .owner = slot,
            .stack = .{ .item = worn.item, .count = 1 },
            .weapon = .{ .item = worn.item, .count = 1 },
            .pickup = if (creative) .creative_only else .allowed,
            .loyalty = @intFromFloat(std.math.clamp(loyalty, 0, 127)),
            .foil = foil,
        });
        if (!creative) {
            const committed = try self.deps.inventories.set(at, held.revision, if (stack.count > 1) .{ .item = stack.item, .count = stack.count - 1 } else null);
            assert(committed);
            self.deps.menus.changed(slot);
        }
        self.sound(player, "minecraft:item.trident.throw", 1);
    }

    /// Riptide: the holder is thrown along its look by the trident's strength, which wears. The
    /// spin attack that hurts what it meets on the way is not dealt here.
    fn launchHolder(self: *Ranged, slot: usize, use_: item_using.Use, strength: f32) !void {
        const player = &self.deps.players.records[slot];
        // TridentItem.releaseUsing, in floats: the look scaled to the strength by Mth.sqrt.
        const direction = mth.shotDirection(player.rotation.pitch, player.rotation.yaw, 0);
        const length = @sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
        const scale = strength / length;
        const push: [3]f64 = .{ direction[0] * scale, direction[1] * scale, direction[2] * scale };
        try self.deps.damage.push(slot, .{ push[0], push[1] + (if (player.on_ground) @as(f64, 1.1999999) else 0), push[2] });
        try self.wear(slot, use_.hand, 1);
        const level: usize = @intFromFloat(std.math.clamp((strength - 1.5) / 0.75, 0, 2));
        const names = [_][]const u8{ "minecraft:item.trident.riptide_1", "minecraft:item.trident.riptide_2", "minecraft:item.trident.riptide_3" };
        self.sound(player, names[level], 1);
    }

    /// Entity.isInWaterOrRain without the rain: water at the feet or the eyes.
    fn inWater(self: *Ranged, slot: usize) !bool {
        const player = &self.deps.players.records[slot];
        for ([_]f64{ 0, 1.62 }) |height| {
            const at: @import("chunks").Position = .{ .x = @intFromFloat(@floor(player.position.x)), .y = @intFromFloat(@floor(player.position.y + height)), .z = @intFromFloat(@floor(player.position.z)) };
            if (self.deps.projectiles.watery.isSet(try self.chunk_client.getBlock(player.world, at))) return true;
        }
        return false;
    }

    fn handSlot(self: *Ranged, slot: usize, hand: item_using.Hand) inventories.Slot {
        const player = &self.deps.players.records[slot];
        return .{ .owner = player.uuid, .index = if (hand == .off) 45 else 36 + @as(u16, self.deps.player_states.of(player).selected_slot) };
    }

    /// The shooter's motion carries over, as Projectile.shootFromRotation adds it.
    fn withMovement(self: *Ranged, slot: usize, velocity: [3]f64) [3]f64 {
        const player = &self.deps.players.records[slot];
        const moved = player.known_movement;
        return .{ velocity[0] + moved[0], velocity[1] + (if (player.on_ground) 0 else moved[1]), velocity[2] + moved[2] };
    }

    /// EnchantmentHelper.processAmmoUse: one arrow a shot, none with Infinity on a plain arrow.
    fn ammoUse(self: *Ranged, weapon: inventories.Stack, ammo_kind: u32) !i32 {
        const pinned = try self.deps.items.acquire(weapon);
        defer pinned.release();
        self.scratch.reset();
        const value = try self.deps.enchantments.effects.modifyFloat(.{ .item = pinned.view, .slot = 0, .any_slot = true, .amount = 1, .channel = .ammo_use, .random = self.random.random(), .scratch = &self.scratch, .item_tags = &self.deps.items.deps.definitions.tags, .tool = ammo_kind });
        return @intFromFloat(@max(0, value));
    }

    fn modify(self: *Ranged, weapon: inventories.Stack, channel: enchantment_effects.Channel, amount: f32) !f32 {
        const pinned = try self.deps.items.acquire(weapon);
        defer pinned.release();
        self.scratch.reset();
        return self.deps.enchantments.effects.modifyFloat(.{ .item = pinned.view, .slot = 0, .any_slot = true, .amount = amount, .channel = channel, .random = self.random.random(), .scratch = &self.scratch, .item_tags = &self.deps.items.deps.definitions.tags });
    }

    /// Flame: the ticks alight a projectile from the weapon starts with.
    fn spawnedFire(self: *Ranged, weapon: inventories.Stack) !i32 {
        const pinned = try self.deps.items.acquire(weapon);
        defer pinned.release();
        var consequences: [8]enchantment_effects.Consequence = undefined;
        const count = try self.deps.enchantments.effects.projectileSpawned(pinned.view, self.random.random(), &consequences);
        var ticks: i32 = 0;
        for (consequences[0..count]) |consequence| switch (consequence.action) {
            // Ignite.apply: igniteForSeconds, so Flame's 100 is a hundred seconds.
            .ignite_seconds => |seconds| ticks = @max(ticks, @as(i32, @intFromFloat(@floor(seconds * 20.0)))),
            .damage, .item_damage => {},
        };
        return ticks;
    }

    fn consume(self: *Ranged, slot: usize, index: u16, ammo: inventories.Contents, amount: u16) !void {
        const stack = ammo.stack.?;
        const at: inventories.Slot = .{ .owner = self.deps.players.records[slot].uuid, .index = index };
        const left: ?inventories.Stack = if (stack.count > amount) .{ .item = stack.item, .count = stack.count - amount } else null;
        const committed = try self.deps.inventories.set(at, ammo.revision, left);
        assert(committed);
        self.deps.menus.changed(slot);
    }

    fn wear(self: *Ranged, slot: usize, hand: item_using.Hand, amount: i32) !void {
        const player = &self.deps.players.records[slot];
        if (self.deps.player_states.of(player).gamemode == .creative) return;
        const at = self.handSlot(slot, hand);
        const held = try self.deps.inventories.get(at);
        const stack = held.stack orelse return;
        self.scratch.reset();
        const worn = try self.deps.durability.wear(stack, .{ .amount = amount, .slot = if (hand == .off) 1 else 0, .actor = player, .random = self.random.random(), .scratch = &self.scratch });
        if (std.meta.eql(worn, held.stack)) return;
        const committed = try self.deps.inventories.set(at, held.revision, worn);
        assert(committed);
        self.deps.menus.changed(slot);
    }

    fn sound(self: *Ranged, player: *const @import("players").player_state.Player, name: []const u8, pitch: f32) void {
        self.effects.sound(player.world, player.position, name, .players, 1, pitch, @bitCast(self.random.next()), null);
    }
};

/// Projectile.shootFromRotation's direction for a player's rotation, no roll.
fn look(rotation: @import("minecraft_model").Rotation) [3]f64 {
    const direction = mth.shotDirection(rotation.pitch, rotation.yaw, 0);
    return .{ direction[0], direction[1], direction[2] };
}
