//! LivingEntity's item use for players: raising an item that is used over time, as shields,
//! bows, crossbows and tridents are, until the client lets it go or the item leaves the hand.
//! Others see the raised hand through the player's living entity flags.

const std = @import("std");
const game_data = @import("game_data");
const minecraft = @import("minecraft_model");
const sessions = @import("sessions");
const inventories = @import("inventories");
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const Items = @import("items.zig").Items;
const item_actions = @import("item_actions.zig");
const ItemCooldowns = @import("item_cooldowns.zig").ItemCooldowns;

const assert = std.debug.assert;

pub const Hand = enum(u1) { main, off };

/// An item being used: in which hand, the stack and its kind, and for how long.
pub const Use = struct {
    generation: u32,
    life: u32,
    hand: Hand,
    item: inventories.ItemId,
    kind: u32,
    /// Ticks since the use started.
    ticks: i32 = 0,
    /// Item.getUseDuration: how long the use may last.
    duration: i32,
};

/// What hears a use let go before it ends: bows and crossbows fire.
pub const Release = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, usize, Use) anyerror!void,
};

pub const ItemUsing = struct {
    pub const id = "minecraft:item_using";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *Players,
        player_states: *PlayerStates,
        inventories: *inventories.Inventories,
        items: *Items,
        actions: *item_actions.ItemActions,
        cooldowns: *ItemCooldowns,
    };
    const releases_max = 8;
    /// Item.getUseDuration of a shield.
    const blocking_duration = 72000;

    deps: Dependencies,
    uses: []?Use,
    releases: [releases_max]Release = undefined,
    release_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemUsing {
        const self = try allocator.create(ItemUsing);
        const uses = try allocator.alloc(?Use, deps.players.records.len);
        @memset(uses, null);
        self.* = .{ .deps = deps, .uses = uses };
        try deps.actions.on(item_actions.Binding.bind(ItemUsing, self, onUse));
        try deps.players.observeDig(self, onDig);
        return self;
    }

    /// Hears each use that is let go before it ends.
    pub fn onRelease(self: *ItemUsing, release: Release) !void {
        if (self.release_count == releases_max) return error.ReleaseCapacity;
        self.releases[self.release_count] = release;
        self.release_count += 1;
    }

    /// The use of the player in a slot, if it is using something in this life.
    pub fn of(self: *ItemUsing, slot: usize) ?Use {
        const use = self.uses[slot] orelse return null;
        const player = &self.deps.players.records[slot];
        const generation = if (player.handle) |handle| handle.generation else 0;
        if (use.generation != generation or use.life != player.life) {
            self.stop(slot);
            return null;
        }
        return use;
    }

    /// LivingEntity.startUsingItem: nothing if the hand is already using something.
    pub fn start(self: *ItemUsing, slot: usize, hand: Hand, stack: inventories.Stack, kind: u32, duration: i32) void {
        assert(duration > 0);
        if (self.of(slot) != null) return;
        const player = &self.deps.players.records[slot];
        const generation = if (player.handle) |handle| handle.generation else 0;
        self.uses[slot] = .{ .generation = generation, .life = player.life, .hand = hand, .item = stack.item, .kind = kind, .duration = duration };
        self.show(slot, .{ .using = true, .off_hand = hand == .off });
    }

    /// LivingEntity.stopUsingItem.
    pub fn stop(self: *ItemUsing, slot: usize) void {
        if (self.uses[slot] == null) return;
        self.uses[slot] = null;
        self.show(slot, .{});
    }

    fn show(self: *ItemUsing, slot: usize, flags: minecraft.LivingFlags) void {
        const player = &self.deps.players.records[slot];
        if (std.meta.eql(player.living_flags, flags)) return;
        player.living_flags = flags;
        player.revision += 1;
    }

    /// Raising an item that blocks attacks, as ShieldItem.use starts using it.
    fn onUse(self: *ItemUsing, context: *const item_actions.Context) !item_actions.Result {
        if (game_data.physics.itemBlocksAttacks(context.item.kind) == null) return .pass;
        const slot = context.player.handle.?.index;
        if (self.deps.cooldowns.active(slot, context.item.kind)) return .pass;
        self.start(slot, if (context.hand == .off) .off else .main, context.stack, context.item.kind, blocking_duration);
        return .applied;
    }

    /// ServerboundPlayerActionPacket's RELEASE_USE_ITEM: LivingEntity.releaseUsingItem.
    fn onDig(self: *ItemUsing, handle: sessions.Handle, dig: minecraft.Dig) !void {
        if (dig.action != .release_use) return;
        const use = self.of(handle.index) orelse return;
        if (!try self.holds(handle.index, use)) return self.stop(handle.index);
        for (self.releases[0..self.release_count]) |release| try release.call(release.context, handle.index, use);
        self.stop(handle.index);
    }

    /// Whether the hand still holds the kind of item it started with, as ItemStack.isSameItem
    /// asks: the use follows the stack as it wears.
    fn holds(self: *ItemUsing, slot: usize, use: Use) !bool {
        const player = &self.deps.players.records[slot];
        const index: u16 = if (use.hand == .off) 45 else 36 + @as(u16, self.deps.player_states.of(player).selected_slot);
        const stack = (try self.deps.inventories.get(.{ .owner = player.uuid, .index = index })).stack orelse return false;
        if (std.mem.eql(u8, &stack.item, &use.item)) return true;
        if (try self.deps.items.kind(stack) != use.kind) return false;
        self.uses[slot].?.item = stack.item;
        return true;
    }

    /// LivingEntity.updatingUsingItem: a use ends when the item leaves the hand or its time is up.
    pub fn tick(self: *ItemUsing) !void {
        for (self.deps.players.activeSlots()) |slot| {
            const use = self.of(slot) orelse continue;
            if (!try self.holds(slot, use)) {
                self.stop(slot);
                continue;
            }
            self.uses[slot].?.ticks += 1;
            if (self.uses[slot].?.ticks >= use.duration) self.stop(slot);
        }
    }
};
