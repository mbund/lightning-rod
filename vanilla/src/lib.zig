const lightning_rod = @import("lightning_rod");
const std = @import("std");

const plugin = lightning_rod.plugin;
pub const Packets = @import("minecraft_packets").Packets;
pub const Status = @import("session_status.zig").Status;
pub const PayloadChannels = @import("payload_channels.zig");
pub const OfflineAuthentication = @import("offline_authentication.zig").OfflineAuthentication;
pub const Keepalive = @import("session_keepalive.zig").Keepalive;
pub const SessionConfiguration = @import("session_configuration.zig").Plugin;
pub const ConfigurationFinish = @import("session_configuration_finish.zig").ConfigurationFinish;
pub const LoginStart = @import("session_login_start.zig").LoginStart;
pub const LoginSuccess = @import("session_login_success.zig").LoginSuccess;
pub const LoginEncryption = @import("session_encryption.zig").LoginEncryption;
pub const LoginCompression = @import("session_compression.zig").LoginCompression;
pub const Disconnect = @import("session_disconnect.zig").Disconnect;
pub const Players = @import("players.zig").Players;
pub const Time = @import("time.zig").Time;
pub const TimeCommands = @import("time_commands.zig").TimeCommands;
pub const Weather = @import("weather.zig").Weather;
pub const Environment = @import("environment.zig").Environment;
pub const Worlds = @import("worlds").Worlds;
pub const VanillaWorlds = @import("default_worlds.zig").VanillaWorlds;
pub const Operators = @import("operators.zig").Operators;
pub const TeleportCommands = @import("teleport_commands.zig").TeleportCommands;
pub const GamemodeCommands = @import("gamemode_commands.zig").GamemodeCommands;
pub const Input = @import("input.zig").Input;
pub const Chat = @import("chat.zig").Chat;
pub const commands = @import("commands");
pub const Reload = @import("reload").Reload;
pub const ReloadCommands = @import("reload_commands.zig").ReloadCommands;
pub const CommandDispatch = @import("commands.zig").CommandDispatch;
pub const FallDamage = @import("fall_damage.zig").FallDamage;
pub const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
pub const SurvivalInventory = @import("survival_inventory.zig").SurvivalInventory;
pub const CreativeInventory = @import("creative_inventory.zig").CreativeInventory;
pub const Replication = @import("replication.zig").Replication;
pub const Chunks = @import("chunks").Chunks;
pub const BlockEdit = @import("chunks").BlockEdit;
pub const SectionEdits = @import("chunks").SectionEdits;
pub const Entities = @import("entities").Entities;
pub const Inventories = @import("inventories").Inventories;
pub const Items = @import("items.zig").Items;
pub const ItemProperties = @import("item_properties.zig").ItemProperties;
pub const Durability = @import("item_properties.zig").Durability;
pub const EquipmentSlots = @import("item_properties.zig").EquipmentSlots;
pub const Lore = @import("item_lore.zig").Lore;
pub const item_lore = @import("item_lore.zig");
pub const item_components = @import("item_components.zig");
pub const item_data = @import("item_data.zig");
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
    plugin.configured(Packets, Packets.Configuration{}),
    plugin.configured(Input, Input.Configuration{}),
    plugin.configured(PayloadChannels.Play, PayloadChannels.Play.Configuration{}),
    plugin.configured(Worlds, Worlds.Configuration{}),
    plugin.configured(VanillaWorlds, VanillaWorlds.Configuration{}),
    plugin.configured(Players, Players.Configuration{}),
    plugin.configured(Time, Time.Configuration{}),
    plugin.configured(Weather, Weather.Configuration{}),
    plugin.configured(Environment, Environment.Configuration{}),
    plugin.configured(Chat, Chat.Configuration{}),
    plugin.configured(commands.Commands, commands.Commands.Configuration{}),
    plugin.configured(Operators, Operators.Configuration{}),
    plugin.configured(TeleportCommands, TeleportCommands.Configuration{}),
    plugin.configured(GamemodeCommands, GamemodeCommands.Configuration{}),
    plugin.configured(TimeCommands, TimeCommands.Configuration{}),
    plugin.configured(Reload, Reload.Configuration{}),
    plugin.configured(ReloadCommands, ReloadCommands.Configuration{}),
    plugin.configured(CommandDispatch, CommandDispatch.Configuration{}),
    plugin.configured(FallDamage, FallDamage.Configuration{}),
    plugin.configured(Replication, Replication.Configuration{}),
    plugin.configured(Chunks, Chunks.Configuration{}),
    plugin.configured(Entities, Entities.Configuration{}),
    plugin.configured(Inventories, Inventories.Configuration{}),
    plugin.configured(Items, Items.Configuration{}),
    plugin.configured(ItemProperties, ItemProperties.Configuration{}),
    plugin.configured(Durability, Durability.Configuration{}),
    plugin.configured(EquipmentSlots, EquipmentSlots.Configuration{}),
    plugin.configured(Lore, Lore.Configuration{}),
    plugin.configured(ItemEntities, ItemEntities.Configuration{}),
    plugin.configured(BlockLoot, BlockLoot.Configuration{}),
    plugin.configured(ItemPhysics, ItemPhysics.Configuration{}),
    plugin.configured(ItemMerging, ItemMerging.Configuration{}),
    plugin.configured(PlayerInventory, PlayerInventory.Configuration{}),
    plugin.configured(SurvivalInventory, SurvivalInventory.Configuration{}),
    plugin.configured(CreativeInventory, CreativeInventory.Configuration{}),
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

pub fn SessionPlugins(comptime Catalog: type) type {
    return std.meta.Tuple(&.{
        plugin.Selection(LoginStart),
        plugin.Selection(LoginEncryption),
        plugin.Selection(Disconnect),
        plugin.Selection(OfflineAuthentication),
        plugin.Selection(LoginCompression),
        plugin.Selection(LoginSuccess),
        plugin.Selection(Keepalive),
        plugin.Selection(Status),
        plugin.Selection(PayloadChannels.Session),
        plugin.Selection(SessionConfiguration(Catalog)),
        plugin.Selection(ConfigurationFinish),
    });
}

pub fn session_plugins(protocols: anytype) SessionPlugins(@typeInfo(@TypeOf(protocols)).pointer.child) {
    const ConfigurationPlugin = SessionConfiguration(@typeInfo(@TypeOf(protocols)).pointer.child);
    return .{
        plugin.configured(LoginStart, LoginStart.Configuration{}),
        plugin.configured(LoginEncryption, LoginEncryption.Configuration{}),
        plugin.configured(Disconnect, Disconnect.Configuration{}),
        plugin.configured(OfflineAuthentication, OfflineAuthentication.Configuration{}),
        plugin.configured(LoginCompression, LoginCompression.Configuration{}),
        plugin.configured(LoginSuccess, LoginSuccess.Configuration{}),
        plugin.configured(Keepalive, Keepalive.Configuration{}),
        plugin.configured(Status, Status.Configuration{}),
        plugin.configured(PayloadChannels.Session, PayloadChannels.Session.Configuration{}),
        plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = protocols }),
        plugin.configured(ConfigurationFinish, ConfigurationFinish.Configuration{}),
    };
}
