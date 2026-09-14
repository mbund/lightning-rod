const std = @import("std");
const plugin = @import("lightning_rod").plugin;
pub const Players = @import("players.zig").Players;
pub const Worlds = @import("worlds").Worlds;
pub const VanillaWorlds = @import("default_worlds.zig").VanillaWorlds;
pub const Operators = @import("operators.zig").Operators;
pub const TeleportCommands = @import("teleport_commands.zig").TeleportCommands;
pub const Input = @import("input.zig").Input;
pub const Chat = @import("chat.zig").Chat;
pub const commands = @import("commands");
pub const Reload = @import("reload").Reload;
pub const ReloadCommands = @import("reload_commands.zig").ReloadCommands;
pub const CommandDispatch = @import("commands.zig").CommandDispatch;
pub const FallDamage = @import("fall_damage.zig").FallDamage;
pub const Menus = @import("menus.zig").Menus;
pub const Replication = @import("replication.zig").Replication;
pub const configuration = @import("configuration.zig");
pub const Chunks = @import("chunks").Chunks;
pub const BlockEdit = @import("chunks").BlockEdit;
pub const Entities = @import("entities").Entities;
pub const Inventories = @import("inventories").Inventories;
pub const Items = @import("items.zig").Items;
pub const ItemMerging = @import("item_merging.zig").ItemMerging;
pub const ItemPickup = @import("item_pickup.zig").ItemPickup;
pub const ItemEntities = @import("item_entities.zig").ItemEntities;
pub const ItemPhysics = @import("item_physics.zig").ItemPhysics;
pub const ItemTick = @import("item_tick.zig").ItemTick;
pub const ItemReplication = @import("item_replication.zig").ItemReplication;
pub const BlockLoot = @import("block_loot.zig").BlockLoot;
pub const Mining = @import("mining.zig").Mining;
pub const Placement = @import("placement.zig").Placement;
pub const BlockActions = @import("block_actions.zig").BlockActions;
pub const Doors = @import("doors.zig").Doors;
pub const Equipment = @import("equipment.zig").Equipment;
pub const item = @import("item.zig");
pub const Flat = @import("flat.zig").Flat;
pub const Streaming = @import("streaming.zig").Streaming;
pub const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;

const defaults = plugin.compose(.{
    plugin.configured(Input, Input.Configuration{}),
    plugin.configured(Worlds, Worlds.Configuration{}),
    plugin.configured(VanillaWorlds, VanillaWorlds.Configuration{}),
    plugin.configured(Players, Players.Configuration{}),
    plugin.configured(Chat, Chat.Configuration{}),
    plugin.configured(commands.Commands, commands.Commands.Configuration{}),
    plugin.configured(Operators, Operators.Configuration{}),
    plugin.configured(TeleportCommands, TeleportCommands.Configuration{}),
    plugin.configured(Reload, Reload.Configuration{}),
    plugin.configured(ReloadCommands, ReloadCommands.Configuration{}),
    plugin.configured(CommandDispatch, CommandDispatch.Configuration{}),
    plugin.configured(FallDamage, FallDamage.Configuration{}),
    plugin.configured(Replication, Replication.Configuration{}),
    plugin.configured(Chunks, Chunks.Configuration{}),
    plugin.configured(Entities, Entities.Configuration{}),
    plugin.configured(Inventories, Inventories.Configuration{}),
    plugin.configured(Items, Items.Configuration{}),
    plugin.configured(ItemEntities, ItemEntities.Configuration{}),
    plugin.configured(BlockLoot, BlockLoot.Configuration{}),
    plugin.configured(ItemPhysics, ItemPhysics.Configuration{}),
    plugin.configured(ItemMerging, ItemMerging.Configuration{}),
    plugin.configured(Menus, Menus.Configuration{}),
    plugin.configured(ItemPickup, ItemPickup.Configuration{}),
    plugin.configured(ItemTick, ItemTick.Configuration{}),
    plugin.configured(Flat, Flat.Configuration{}),
    plugin.configured(Streaming, Streaming.Configuration{}),
    plugin.configured(BlockSynchronization, BlockSynchronization.Configuration{}),
    plugin.configured(BlockActions, BlockActions.Configuration{}),
    plugin.configured(Doors, Doors.Configuration{}),
    plugin.configured(Mining, Mining.Configuration{}),
    plugin.configured(Placement, Placement.Configuration{}),
    plugin.configured(Equipment, Equipment.Configuration{}),
    plugin.configured(ItemReplication, ItemReplication.Configuration{}),
});

pub fn plugins() @TypeOf(defaults) {
    return defaults;
}

pub const Protocols = ProtocolSet(&.{ 771, 772 });

pub fn ProtocolSet(comptime numbers: []const i32) type {
    if (numbers.len == 0) @compileError("select at least one protocol");

    for (numbers, 0..) |number, index| {
        if (number != 771 and number != 772) @compileError("unsupported vanilla protocol");

        for (numbers[0..index]) |previous| if (previous == number) @compileError("duplicate protocol");
    }

    return struct {
        plans: [numbers.len]configuration.Plan,
        values: [numbers.len]configuration.ConfigurationData,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            var result: @This() = undefined;
            var initialized: usize = 0;
            errdefer for (result.plans[0..initialized]) |*plan| plan.deinit(allocator);

            inline for (numbers, 0..) |number, index| {
                const version = if (number == 771) "1.21.6" else "1.21.8";
                const snapshot = try configuration.Snapshot.read(allocator, @embedFile("registries-" ++ version ++ ".bin"), version);
                defer snapshot.deinit(allocator);
                result.plans[index] = try configuration.build(allocator, number, snapshot);
                initialized += 1;
                result.values[index] = result.plans[index].configurationData();
            }

            return result;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (&self.plans) |*plan| plan.deinit(allocator);
            self.* = undefined;
        }
    };
}
