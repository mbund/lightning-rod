//! Boat items, with chests or without: BoatItem.use puts the item's boat where the player looks, on a block or on any
//! fluid, facing as the player faces, where it is clear.

const std = @import("std");
const game_data = @import("game_data");
const inventories = @import("inventories");
const entities = @import("entities");
const ItemActions = @import("vanilla_items").item_actions.ItemActions;
const item_actions = @import("vanilla_items").item_actions;
const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const Player = @import("players").player_state.Player;
const bodies = @import("vanilla_bodies");
const boat_module = @import("boat.zig");
const Boats = @import("boats.zig").Boats;

const mth = bodies.mth;
const body = bodies.body;
const clip = bodies.clip;
const assert = std.debug.assert;

pub const BoatItems = struct {
    pub const id = "minecraft:boat_items";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        actions: *ItemActions,
        boats: *Boats,
        player_states: *PlayerStates,
        attributes: *EquipmentAttributes,
        inventories: *inventories.Inventories,
        menus: *PlayerInventory,
    };

    deps: Dependencies,
    /// The item of each model's boat, by registry id.
    items: [Boats.Model.count]u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*BoatItems {
        const self = try allocator.create(BoatItems);
        var items: [Boats.Model.count]u32 = undefined;
        for (&items, 0..) |*item, index| item.* = @intCast(game_data.registry.itemId(Boats.Model.at(index).name()) orelse return error.UnknownItem);
        self.* = .{ .deps = deps, .items = items };
        try deps.actions.on(item_actions.Binding.bind(BoatItems, self, use));
        return self;
    }

    fn modelOf(self: *const BoatItems, item: u32) ?Boats.Model {
        for (self.items, 0..) |known, index| if (known == item) return Boats.Model.at(index);
        return null;
    }

    /// BoatItem.use, which answers using the item in the air: clicking a block passes to it.
    fn use(self: *BoatItems, context: *const item_actions.Context) !item_actions.Result {
        if (context.hit != null) return .pass;
        const model = self.modelOf(context.item.kind) orelse return .pass;
        const player = context.player;
        const boats = self.deps.boats;
        const level = boats.deps.mobs.level(player.world);
        const creative = self.deps.player_states.of(player).gamemode == .creative;
        const eye = eyeOf(player);
        const view = viewVector(player.rotation.pitch, player.rotation.yaw);
        // Player.blockInteractionRange, with creative's half block more.
        const range = try self.deps.attributes.value(player.handle.?.index, "minecraft:block_interaction_range") + @as(f64, if (creative) 0.5 else 0);
        const end: [3]f64 = .{ eye[0] + view[0] * range, eye[1] + view[1] * range, eye[2] + view[2] * range };
        const hit = try clip.clip(&level, eye, end, .any) orelse return .pass;
        // A pickable entity whose box holds the eyes is what the player uses, not the water.
        const reach = playerBox(player).expandTowards(.{ view[0] * 5, view[1] * 5, view[2] * 5 }).inflate(1, 1, 1);
        if (try boats.pickableHolds(player.world, reach, eye)) return .pass;
        const placed = boat_module.boxAt(hit.location);
        if (!try boats.clear(player.world, placed, hit.location[1], null)) return .denied;
        _ = try boats.spawn(.{ .model = model, .world = player.world, .position = hit.location, .yaw = player.rotation.yaw });
        if (!creative) try self.consume(context);
        return .applied;
    }

    /// The boat is used up, but in creative.
    fn consume(self: *BoatItems, context: *const item_actions.Context) !void {
        const player = context.player;
        const state = self.deps.player_states.of(player);
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = if (context.hand == .off) 45 else 36 + @as(u16, state.selected_slot) };
        const held = try self.deps.inventories.get(slot);
        const stack = held.stack orelse return;
        const committed = try self.deps.inventories.set(slot, held.revision, if (stack.count > 1) .{ .item = stack.item, .count = stack.count - 1 } else null);
        assert(committed);
        self.deps.menus.changed(player.handle.?.index);
    }
};

/// Entity.getEyePosition for a player standing or sneaking.
fn eyeOf(player: *const Player) [3]f64 {
    return .{ player.position.x, player.position.y + @as(f64, @as(f32, if (player.flags.sneaking) 1.27 else 1.62)), player.position.z };
}

/// A player's box, standing or sneaking.
fn playerBox(player: *const Player) body.Box {
    return body.makeBox(.{ player.position.x, player.position.y, player.position.z }, 0.6, if (player.flags.sneaking) 1.5 else 1.8);
}

/// Entity.calculateViewVector: where the rotation looks, from the sine table, as floats.
pub fn viewVector(pitch: f32, yaw: f32) [3]f64 {
    const f = pitch * 0.017453292;
    const g = -yaw * 0.017453292;
    const h = mth.cos(g);
    const i = mth.sin(g);
    const j = mth.cos(f);
    const k = mth.sin(f);
    return .{ i * j, -k, h * j };
}
