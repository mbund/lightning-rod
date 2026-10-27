const lightning_rod = @import("lightning_rod");
const std = @import("std");
const sessions = @import("sessions");
const records = @import("records");
pub const Packets = @import("minecraft_packets").Packets;
pub const Status = @import("session_status.zig").Status;
pub const PayloadChannels = @import("payload_channels.zig");
pub const OfflineAuthentication = @import("offline_authentication.zig").OfflineAuthentication;
pub const Keepalive = @import("session_keepalive.zig").Keepalive;
pub const SessionConfiguration = @import("session_configuration.zig").Plugin;
pub const LoginStart = @import("session_login_start.zig").LoginStart;
pub const LoginSuccess = @import("session_login_success.zig").LoginSuccess;
pub const LoginEncryption = @import("session_encryption.zig").LoginEncryption;
pub const LoginCompression = @import("session_compression.zig").LoginCompression;
pub const Disconnect = @import("session_disconnect.zig").Disconnect;
pub const Bossbars = @import("bossbars.zig").Bossbars;
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
pub const ChatInput = @import("chat_input.zig").ChatInput;
pub const JoinLeaveMessages = @import("join_leave_messages.zig").JoinLeaveMessages;
pub const commands = @import("commands");
pub const Reload = @import("reload").Reload;
pub const ReloadCommands = @import("reload_commands.zig").ReloadCommands;
pub const CommandDispatch = @import("commands.zig").CommandDispatch;
pub const FallDamage = @import("fall_damage.zig").FallDamage;
pub const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
pub const SurvivalInventory = @import("survival_inventory.zig").SurvivalInventory;
pub const CreativeInventory = @import("creative_inventory.zig").CreativeInventory;
pub const Visibility = @import("visibility.zig").Visibility;
pub const Replication = @import("replication.zig").Replication;
pub const ChunkSource = @import("chunks").Source;
pub const Chunks = @import("chunks").Chunks;
pub const Section = @import("chunks").Section;
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
pub const Generation = @import("generation.zig").Generation;
pub const Terrain = @import("terrain.zig").Terrain;
pub const ThreadedTerrain = @import("terrain.zig").ThreadedTerrain;
pub const Streaming = @import("streaming.zig").Streaming;
pub const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;
pub const RegistryIdentity = @import("registry_identity.zig").RegistryIdentity;

pub const RecordWorkspaces = records.Workspaces;

const defaults = lightning_rod.plugin.compose(.{
    lightning_rod.plugin.configured(RecordWorkspaces, .{}),
    lightning_rod.plugin.configured(sessions.World, .{}),
    lightning_rod.plugin.configured(RegistryIdentity, RegistryIdentity.Configuration{}),
    lightning_rod.plugin.configured(Packets, Packets.Configuration{}),
    lightning_rod.plugin.configured(Input, Input.Configuration{}),
    lightning_rod.plugin.configured(PayloadChannels.Play, PayloadChannels.Play.Configuration{}),
    lightning_rod.plugin.configured(Worlds, Worlds.Configuration{}),
    lightning_rod.plugin.configured(VanillaWorlds, VanillaWorlds.Configuration{}),
    lightning_rod.plugin.configured(Players, Players.Configuration{}),
    lightning_rod.plugin.configured(Visibility, Visibility.Configuration{}),
    lightning_rod.plugin.configured(Bossbars, Bossbars.Configuration{}),
    lightning_rod.plugin.configured(Time, Time.Configuration{}),
    lightning_rod.plugin.configured(Weather, Weather.Configuration{}),
    lightning_rod.plugin.configured(Environment, Environment.Configuration{}),
    lightning_rod.plugin.configured(Chat, Chat.Configuration{}),
    lightning_rod.plugin.configured(ChatInput, ChatInput.Configuration{}),
    lightning_rod.plugin.configured(JoinLeaveMessages, JoinLeaveMessages.Configuration{}),
    lightning_rod.plugin.configured(commands.Commands, commands.Commands.Configuration{}),
    lightning_rod.plugin.configured(Operators, Operators.Configuration{}),
    lightning_rod.plugin.configured(TeleportCommands, TeleportCommands.Configuration{}),
    lightning_rod.plugin.configured(GamemodeCommands, GamemodeCommands.Configuration{}),
    lightning_rod.plugin.configured(TimeCommands, TimeCommands.Configuration{}),
    lightning_rod.plugin.configured(Reload, Reload.Configuration{}),
    lightning_rod.plugin.configured(ReloadCommands, ReloadCommands.Configuration{}),
    lightning_rod.plugin.configured(CommandDispatch, CommandDispatch.Configuration{}),
    lightning_rod.plugin.configured(FallDamage, FallDamage.Configuration{}),
    lightning_rod.plugin.configured(Replication, Replication.Configuration{}),
    lightning_rod.plugin.configured(Chunks, Chunks.Configuration{}),
    lightning_rod.plugin.configured(Entities, Entities.Configuration{}),
    lightning_rod.plugin.configured(Inventories, Inventories.Configuration{}),
    lightning_rod.plugin.configured(Items, Items.Configuration{}),
    lightning_rod.plugin.configured(ItemProperties, ItemProperties.Configuration{}),
    lightning_rod.plugin.configured(Durability, Durability.Configuration{}),
    lightning_rod.plugin.configured(EquipmentSlots, EquipmentSlots.Configuration{}),
    lightning_rod.plugin.configured(Lore, Lore.Configuration{}),
    lightning_rod.plugin.configured(ItemEntities, ItemEntities.Configuration{}),
    lightning_rod.plugin.configured(BlockLoot, BlockLoot.Configuration{}),
    lightning_rod.plugin.configured(ItemPhysics, ItemPhysics.Configuration{}),
    lightning_rod.plugin.configured(ItemMerging, ItemMerging.Configuration{}),
    lightning_rod.plugin.configured(PlayerInventory, PlayerInventory.Configuration{}),
    lightning_rod.plugin.configured(SurvivalInventory, SurvivalInventory.Configuration{}),
    lightning_rod.plugin.configured(CreativeInventory, CreativeInventory.Configuration{}),
    lightning_rod.plugin.configured(ItemPickup, ItemPickup.Configuration{}),
    lightning_rod.plugin.configured(ItemTick, ItemTick.Configuration{}),
    lightning_rod.plugin.configured(Flat, Flat.Configuration{}),
    lightning_rod.plugin.configured(Streaming, Streaming.Configuration{}),
    lightning_rod.plugin.configured(BlockSynchronization, BlockSynchronization.Configuration{}),
    lightning_rod.plugin.configured(BlockActions, BlockActions.Configuration{}),
    lightning_rod.plugin.configured(Doors, Doors.Configuration{}),
    lightning_rod.plugin.configured(Mining, Mining.Configuration{}),
    lightning_rod.plugin.configured(Placement, Placement.Configuration{}),
    lightning_rod.plugin.configured(Equipment, Equipment.Configuration{}),
    lightning_rod.plugin.configured(ItemReplication, ItemReplication.Configuration{}),
});

pub fn plugins() @TypeOf(defaults) {
    return defaults;
}

pub fn SessionPlugins(comptime Catalog: type) type {
    return std.meta.Tuple(&.{
        lightning_rod.plugin.Selection(LoginStart),
        lightning_rod.plugin.Selection(LoginEncryption),
        lightning_rod.plugin.Selection(Disconnect),
        lightning_rod.plugin.Selection(OfflineAuthentication),
        lightning_rod.plugin.Selection(LoginCompression),
        lightning_rod.plugin.Selection(LoginSuccess),
        lightning_rod.plugin.Selection(Keepalive),
        lightning_rod.plugin.Selection(Status),
        lightning_rod.plugin.Selection(PayloadChannels.Session),
        lightning_rod.plugin.Selection(SessionConfiguration(Catalog)),
    });
}

pub fn session_plugins(protocols: anytype) SessionPlugins(@typeInfo(@TypeOf(protocols)).pointer.child) {
    const ConfigurationPlugin = SessionConfiguration(@typeInfo(@TypeOf(protocols)).pointer.child);
    return .{
        lightning_rod.plugin.configured(LoginStart, LoginStart.Configuration{}),
        lightning_rod.plugin.configured(LoginEncryption, LoginEncryption.Configuration{}),
        lightning_rod.plugin.configured(Disconnect, Disconnect.Configuration{}),
        lightning_rod.plugin.configured(OfflineAuthentication, OfflineAuthentication.Configuration{}),
        lightning_rod.plugin.configured(LoginCompression, LoginCompression.Configuration{}),
        lightning_rod.plugin.configured(LoginSuccess, LoginSuccess.Configuration{}),
        lightning_rod.plugin.configured(Keepalive, Keepalive.Configuration{}),
        lightning_rod.plugin.configured(Status, Status.Configuration{}),
        lightning_rod.plugin.configured(PayloadChannels.Session, PayloadChannels.Session.Configuration{}),
        lightning_rod.plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = protocols }),
    };
}
