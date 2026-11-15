const std = @import("std");
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const minecraft = @import("minecraft_model");
const inventories = @import("inventories");
const Player = @import("players").player_state.Player;
const Items = @import("items.zig").Items;
const item_data = @import("item_data.zig");
const behavior = @import("vanilla_content").behavior;

/// The first non-pass result consumes the action. Passing handlers leave gameplay unchanged.
pub const Result = enum { pass, applied, denied };
pub const Context = struct {
    player: *const Player,
    item: item_data.View,
    stack: inventories.Stack,
    hand: enum { main, off },
    hit: ?minecraft.Place,
    scratch: *std.heap.FixedBufferAllocator,
};
pub const Binding = behavior.Binding(Context, Result);
pub const Handler = Binding.Handler;

pub const ItemActions = struct {
    pub const id = "minecraft:item_actions";
    pub const Configuration = struct { maximum_handlers: usize = 16, scratch_bytes: usize = 16 * 1024 };
    pub const Dependencies = struct { player_states: *PlayerStates, items: *Items };
    deps: Dependencies,
    handlers: []Binding,
    count: usize = 0,
    sealed: bool = false,
    applying: bool = false,
    scratch: std.heap.FixedBufferAllocator,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*ItemActions {
        if (configuration.maximum_handlers == 0 or configuration.scratch_bytes == 0) return error.InvalidConfiguration;
        const self = try allocator.create(ItemActions);
        self.* = .{
            .deps = deps,
            .handlers = try allocator.alloc(Binding, configuration.maximum_handlers),
            .scratch = .init(try allocator.alloc(u8, configuration.scratch_bytes)),
        };
        return self;
    }

    pub fn on(self: *ItemActions, handler: Binding) !void {
        std.debug.assert(!self.sealed);
        if (self.count == self.handlers.len) return error.ItemActionCapacity;
        self.handlers[self.count] = handler;
        self.count += 1;
    }

    pub fn apply(self: *ItemActions, player: *const Player, hand: i32, hit: ?minecraft.Place) !Result {
        self.sealed = true;
        if (hand < 0 or hand > 1 or player.stage != .ready) return .denied;
        const state = self.deps.player_states.of(player);
        if (state.health <= 0 or state.gamemode == .spectator) return .denied;
        if (self.count == 0) return .pass;
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = if (hand == 1) 45 else 36 + @as(u16, state.selected_slot) };
        const stack = (try self.deps.items.deps.inventories.get(slot)).stack orelse return .pass;
        std.debug.assert(!self.applying);
        self.applying = true;
        defer self.applying = false;
        const pinned = try self.deps.items.acquire(stack);
        defer pinned.release();
        defer self.scratch.reset();
        for (self.handlers[0..self.count]) |handler| {
            self.scratch.reset();
            const result = try handler.call(&.{ .player = player, .item = pinned.view, .stack = stack, .hand = if (hand == 0) .main else .off, .hit = hit, .scratch = &self.scratch });
            if (result != .pass) return result;
        }
        return .pass;
    }
};
