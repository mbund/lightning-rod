//! Vanilla gameplay as plugins on the engine, and the default server that composes them with
//! the engine's own plugins.
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const records = @import("records");
const commands = @import("commands");
const Chunks = @import("chunks").Chunks;
const Entities = @import("entities").Entities;
const Inventories = @import("inventories").Inventories;
const Worlds = @import("worlds").Worlds;
const Reload = @import("reload").Reload;
const Packets = @import("minecraft_packets").Packets;
const Input = @import("players").input.Input;
const Players = @import("players").players.Players;
const Domains = @import("domains").domains.Domains;
const game_data = @import("game_data");
const Ticks = @import("ticks").ticks.Ticks;
pub const RandomTicks = @import("random_ticks").random_ticks.RandomTicks;
const PayloadChannels = @import("connection").payload_channels;
const Visibility = @import("replication").visibility.Visibility;
const Replication = @import("replication").replication.Replication;
const Bossbars = @import("bossbars").bossbars.Bossbars;
const Chat = @import("chat").chat.Chat;
const ChatInput = commands.chat_input.ChatInput;
const Operators = commands.operators.Operators;
const ReloadCommands = commands.reload_commands.ReloadCommands;
const CommandDispatch = commands.dispatch.CommandDispatch;
const Lighting = @import("terrain").lighting.Lighting;
const Streaming = @import("terrain").streaming.Streaming;
const BlockSynchronization = @import("terrain").block_sync.BlockSynchronization;
const RecordWorkspaces = records.Workspaces;

pub const smelting = @import("vanilla_crafting").smelting;
pub const enchantment_effects = @import("vanilla_items").enchantment_effects;
pub const placement_behavior = @import("vanilla_blocks").placement_behavior;
pub const mining_behavior = @import("vanilla_blocks").mining_behavior;
pub const fuel = @import("vanilla_crafting").fuel;
pub const Datapacks = @import("vanilla_definitions").datapacks.Datapacks;
pub const tags = @import("vanilla_content").content_tags;
pub const recipes = @import("vanilla_crafting").recipes;
pub const loot = @import("vanilla_items").loot;
pub const crafting = @import("vanilla_crafting").crafting;
pub const custom_data = @import("vanilla_content").custom_data;
pub const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
pub const Spawn = @import("vanilla_world").spawn.Spawn;
pub const Time = @import("vanilla_world").time.Time;
pub const TimeCommands = @import("vanilla_world").time_commands.TimeCommands;
pub const Weather = @import("vanilla_world").weather.Weather;
pub const Environment = @import("vanilla_world").environment.Environment;
pub const VanillaWorlds = @import("vanilla_world").default_worlds.VanillaWorlds;
pub const TeleportCommands = @import("vanilla_world").teleport_commands.TeleportCommands;
pub const GamemodeCommands = @import("vanilla_player").gamemode_commands.GamemodeCommands;
pub const JoinLeaveMessages = @import("vanilla_player").join_leave_messages.JoinLeaveMessages;
pub const FallDamage = @import("vanilla_survival").fall_damage.FallDamage;
pub const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
pub const definitions = @import("vanilla_definitions").defaults.definitions;
pub const prepareDefinitions = @import("vanilla_definitions").defaults.prepare;
pub const definition_provider = @import("vanilla_definitions").definition_provider;
pub const Vanilla = @import("vanilla_definitions").defaults.Vanilla;
pub const Crafting = @import("vanilla_crafting").crafting_registry.Crafting;
pub const Furnaces = @import("vanilla_crafting").furnaces.Furnaces;
pub const Loot = @import("vanilla_items").loot_registry.Loot;
pub const Dimensions = @import("vanilla_content").dimensions.Dimensions;
pub const Blocks = @import("vanilla_content").blocks.Blocks;
pub const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
pub const RecipeCommands = @import("vanilla_containers").recipe_commands.RecipeCommands;
pub const RecipeBook = @import("vanilla_containers").recipe_book.RecipeBook;
pub const InventoryMenus = @import("vanilla_containers").inventory_menus.InventoryMenus;
pub const CreativeInventory = @import("vanilla_inventory").creative_inventory.CreativeInventory;
pub const InventoryCapacity = @import("vanilla_inventory").inventory_capacity.InventoryCapacity;
pub const Items = @import("vanilla_items").items.Items;
pub const ItemProperties = @import("vanilla_items").item_properties.ItemProperties;
pub const Durability = @import("vanilla_items").item_properties.Durability;
pub const EquipmentAttributes = @import("vanilla_items").equipment_attributes.EquipmentAttributes;
pub const EquipmentSlots = @import("vanilla_items").item_properties.EquipmentSlots;
pub const Lore = @import("vanilla_items").item_lore.Lore;
pub const item_lore = @import("vanilla_items").item_lore;
pub const item_components = @import("vanilla_items").item_components;
pub const item_data = @import("vanilla_items").item_data;
pub const ItemMerging = @import("vanilla_item_entities").item_merging.ItemMerging;
pub const ItemPickup = @import("vanilla_inventory").item_pickup.ItemPickup;
pub const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
pub const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
pub const raycast = @import("vanilla_blocks").raycast;
pub const ItemUse = @import("vanilla_blocks").item_use.ItemUse;
pub const ItemActions = @import("vanilla_items").item_actions.ItemActions;
pub const item_actions = @import("vanilla_items").item_actions;
pub const Enchantments = @import("vanilla_items").enchantments.Enchantments;
pub const ItemContent = @import("vanilla_items").item_content.ItemContent;
pub const Experience = @import("vanilla_survival").experience.Experience;
pub const ExperienceReplication = @import("vanilla_survival").experience_replication.ExperienceReplication;
pub const ItemTick = @import("vanilla_inventory").item_tick.ItemTick;
pub const ItemReplication = @import("vanilla_inventory").item_replication.ItemReplication;
pub const BlockLoot = @import("vanilla_blocks").block_loot.BlockLoot;
pub const Mining = @import("vanilla_blocks").mining.Mining;
pub const Growth = @import("vanilla_blocks").growth.Growth;
pub const Fluids = @import("vanilla_blocks").fluids.Fluids;
pub const Placement = @import("vanilla_blocks").placement.Placement;
pub const BlockActions = @import("vanilla_blocks").block_actions.BlockActions;
pub const container_storage = @import("vanilla_containers").containers;
pub const furnace_state = @import("vanilla_containers").furnace;
pub const content_components = @import("vanilla_definitions").content_components;
pub const Containers = @import("vanilla_containers").containers.Containers;
pub const Doors = @import("vanilla_blocks").doors.Doors;
pub const Equipment = @import("vanilla_equipment").equipment.Equipment;
pub const item = @import("vanilla_item_entities").item;
pub const Flat = @import("vanilla_world").flat.Flat;
pub const RegistryIdentity = @import("vanilla_content").registry_identity.RegistryIdentity;

const defaults = lightning_rod.plugin.compose(.{
    lightning_rod.plugin.configured(Items.Registry, .{}),
    lightning_rod.plugin.configured(Blocks, .{}),
    lightning_rod.plugin.configured(Dimensions, .{}),
    lightning_rod.plugin.configured(Enchantments.Registry, .{}),
    lightning_rod.plugin.configured(ClientRegistries, .{}),
    lightning_rod.plugin.configured(Crafting, .{}),
    lightning_rod.plugin.configured(Furnaces, .{}),
    lightning_rod.plugin.configured(Loot, .{}),
    lightning_rod.plugin.configured(Mining.Registry, .{}),
    lightning_rod.plugin.configured(Placement.Registry, .{}),
    lightning_rod.plugin.configured(RecipeBook.Registry, .{}),
    lightning_rod.plugin.configured(Vanilla, .{}),
    lightning_rod.plugin.configured(RecordWorkspaces, .{}),
    lightning_rod.plugin.configured(sessions.World, .{}),
    lightning_rod.plugin.configured(RegistryIdentity, RegistryIdentity.Configuration{}),
    lightning_rod.plugin.configured(Packets, Packets.Configuration{}),
    lightning_rod.plugin.configured(Input, Input.Configuration{}),
    lightning_rod.plugin.configured(PayloadChannels.Play, PayloadChannels.Play.Configuration{}),
    lightning_rod.plugin.configured(Worlds, Worlds.Configuration{}),
    lightning_rod.plugin.configured(VanillaWorlds, VanillaWorlds.Configuration{}),
    lightning_rod.plugin.configured(Chunks, Chunks.Configuration.forPlayers((Players.Configuration{}).maximum)),
    lightning_rod.plugin.configured(Spawn, Spawn.Configuration{}),
    lightning_rod.plugin.configured(Players, Players.Configuration{}),
    lightning_rod.plugin.configured(PlayerStates, PlayerStates.Configuration{}),
    lightning_rod.plugin.configured(Domains, Domains.Configuration{}),
    lightning_rod.plugin.configured(Ticks, Ticks.Configuration{}),
    lightning_rod.plugin.configured(RandomTicks.Registry, RandomTicks.Registry.Configuration{ .states = @intCast(game_data.registry.block_state_names.len) }),
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
    lightning_rod.plugin.configured(Entities, Entities.Configuration{}),
    lightning_rod.plugin.configured(InventoryCapacity, .{}),
    lightning_rod.plugin.configured(Inventories, Inventories.Configuration{ .cache_items = crafting.maximum_inputs + 1 }),
    lightning_rod.plugin.configured(Items, Items.Configuration{}),
    lightning_rod.plugin.configured(ItemProperties, ItemProperties.Configuration{}),
    lightning_rod.plugin.configured(Durability, Durability.Configuration{}),
    lightning_rod.plugin.configured(EquipmentSlots, EquipmentSlots.Configuration{}),
    lightning_rod.plugin.configured(EquipmentAttributes, .{}),
    lightning_rod.plugin.configured(ItemActions, .{}),
    lightning_rod.plugin.configured(Enchantments, .{}),
    lightning_rod.plugin.configured(FallDamage, .{}),
    lightning_rod.plugin.configured(ItemContent, .{}),
    lightning_rod.plugin.configured(Lore, Lore.Configuration{}),
    lightning_rod.plugin.configured(ItemEntities, ItemEntities.Configuration{}),
    lightning_rod.plugin.configured(BlockLoot, BlockLoot.Configuration{}),
    lightning_rod.plugin.configured(ItemPhysics, ItemPhysics.Configuration{}),
    lightning_rod.plugin.configured(ItemMerging, ItemMerging.Configuration{}),
    lightning_rod.plugin.configured(BlockActions, BlockActions.Configuration{}),
    lightning_rod.plugin.configured(PlayerInventory, PlayerInventory.Configuration{}),
    lightning_rod.plugin.configured(Experience, .{}),
    lightning_rod.plugin.configured(Containers, Containers.Configuration{}),
    lightning_rod.plugin.configured(InventoryMenus, InventoryMenus.Configuration{}),
    lightning_rod.plugin.configured(RecipeBook, .{}),
    lightning_rod.plugin.configured(RecipeCommands, .{}),
    lightning_rod.plugin.configured(CreativeInventory, CreativeInventory.Configuration{}),
    lightning_rod.plugin.configured(ItemPickup, ItemPickup.Configuration{}),
    lightning_rod.plugin.configured(ItemTick, ItemTick.Configuration{}),
    lightning_rod.plugin.configured(Flat, Flat.Configuration{}),
    lightning_rod.plugin.configured(Lighting, Lighting.Configuration{}),
    lightning_rod.plugin.configured(Streaming, Streaming.Configuration{}),
    lightning_rod.plugin.configured(Replication, Replication.Configuration{}),
    lightning_rod.plugin.configured(ExperienceReplication, .{}),
    lightning_rod.plugin.configured(BlockSynchronization, BlockSynchronization.Configuration{}),
    lightning_rod.plugin.configured(ItemUse, .{}),
    lightning_rod.plugin.configured(Doors, Doors.Configuration{}),
    lightning_rod.plugin.configured(Mining, Mining.Configuration{}),
    lightning_rod.plugin.configured(Placement, Placement.Configuration{}),
    lightning_rod.plugin.configured(Growth, Growth.Configuration{}),
    lightning_rod.plugin.configured(Fluids, Fluids.Configuration{}),
    lightning_rod.plugin.configured(RandomTicks, RandomTicks.Configuration{}),
    lightning_rod.plugin.configured(Equipment, Equipment.Configuration{}),
    lightning_rod.plugin.configured(ItemReplication, ItemReplication.Configuration{}),
});

pub fn plugins() @TypeOf(defaults) {
    return defaults;
}
