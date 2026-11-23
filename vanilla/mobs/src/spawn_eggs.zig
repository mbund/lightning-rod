//! Spawn eggs: SpawnEggItem.useOn makes the egg's mob on the clicked block, or in it when it
//! has no collision shape, through EntityType.spawn.

const std = @import("std");
const game_data = @import("game_data");
const inventories = @import("inventories");
const ItemActions = @import("vanilla_items").item_actions.ItemActions;
const item_actions = @import("vanilla_items").item_actions;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const mth = @import("vanilla_bodies").mth;
const body = @import("vanilla_bodies").body;
const mob_state = @import("mob.zig");
const mob_replication = @import("mob_replication.zig");
const Mobs = @import("mobs.zig").Mobs;

const assert = std.debug.assert;

pub const SpawnEggs = struct {
    pub const id = "minecraft:spawn_eggs";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        actions: *ItemActions,
        mobs: *Mobs,
        player_states: *PlayerStates,
        inventories: *inventories.Inventories,
        menus: *PlayerInventory,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*SpawnEggs {
        const self = try allocator.create(SpawnEggs);
        self.* = .{ .deps = deps };
        try deps.actions.on(item_actions.Binding.bind(SpawnEggs, self, use));
        return self;
    }

    fn speciesOf(item: u32) ?mob_state.Species {
        const entity = game_data.physics.spawnEgg(@intCast(item)) orelse return null;
        const name = game_data.registry.entityName(@intCast(entity)) orelse return null;
        if (std.mem.eql(u8, name, "minecraft:cow")) return .cow;
        return null;
    }

    fn use(self: *SpawnEggs, context: *const item_actions.Context) !item_actions.Result {
        const hit = context.hit orelse return .pass;
        const species = speciesOf(context.item.kind) orelse return .pass;
        const player = context.player;
        const mobs = self.deps.mobs;
        const level = mobs.level(player.world);
        const clicked: [3]i32 = .{ hit.position.x, hit.position.y, hit.position.z };
        const state = try level.state(clicked[0], clicked[1], clicked[2]);
        const offsets = [_][3]i32{ .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 } };
        const face: usize = @intCast(std.math.clamp(hit.face, 0, 5));
        const position = if (body.contextFreeBoxes(state, clicked[0], clicked[2]).count == 0) clicked else [3]i32{ clicked[0] + offsets[face][0], clicked[1] + offsets[face][1], clicked[2] + offsets[face][2] };
        const invert = !std.meta.eql(position, clicked) and face == 1;
        const traits = mobs.traits(species);
        const x = @as(f64, @floatFromInt(position[0])) + 0.5;
        const z = @as(f64, @floatFromInt(position[2])) + 0.5;
        const y_offset = try yOffset(&level, position, invert, body.makeBox(.{ x, @as(f64, @floatFromInt(position[1])) + 1, z }, traits.width, traits.height));
        const yaw = mth.wrapDegrees(mobs.levelRandom().nextFloat() * 360.0);
        const entity = try mobs.spawn(.{
            .species = species,
            .world = player.world,
            .position = .{ x, @as(f64, @floatFromInt(position[1])) + y_offset, z },
            .yaw = yaw,
            .variant = mob_replication.default_variant,
        });
        // EntityType.create and EntityType.spawn each play the ambient sound.
        const mob = (try mobs.get(entity)).?;
        mobs.ambientSound(mob);
        mobs.ambientSound(mob);
        try self.consume(context);
        return .applied;
    }

    /// EntityType.getYOffset: how far the mob sinks onto what is in the block it spawns in, or
    /// the block below when it was placed against the top of one.
    fn yOffset(level: *const body.Level, position: [3]i32, invert: bool, start: body.Box) !f64 {
        const origin: [3]f64 = .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
        var query: body.Box = .{ .min = origin, .max = .{ origin[0] + 1, origin[1] + 1, origin[2] + 1 } };
        if (invert) query.min[1] -= 1;
        const distance = try body.collideVertical(level, query, .{ .empty = true }, start, if (invert) -2.0 else -1.0);
        return 1.0 + distance;
    }

    /// The egg is used up, but in creative, where ServerPlayerGameMode restores the count.
    fn consume(self: *SpawnEggs, context: *const item_actions.Context) !void {
        const player = context.player;
        const state = self.deps.player_states.of(player);
        if (state.gamemode == .creative) return;
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = if (context.hand == .off) 45 else 36 + @as(u16, state.selected_slot) };
        const held = try self.deps.inventories.get(slot);
        const stack = held.stack orelse return;
        const committed = try self.deps.inventories.set(slot, held.revision, if (stack.count > 1) .{ .item = stack.item, .count = stack.count - 1 } else null);
        assert(committed);
        self.deps.menus.changed(player.handle.?.index);
    }
};
