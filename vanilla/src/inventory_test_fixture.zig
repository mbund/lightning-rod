const definition_provider = @import("vanilla_definitions").definition_provider;
const vanilla_content = @import("vanilla_definitions").defaults;
const crafting = @import("vanilla_crafting").crafting;
const menu_click = @import("vanilla_inventory").menu_click;
const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const worlds = @import("worlds");
const entities = @import("entities");
const inventories = @import("inventories");
const sessions = @import("sessions");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const InventoryMenus = @import("vanilla_containers").inventory_menus.InventoryMenus;
const CreativeInventory = @import("vanilla_inventory").creative_inventory.CreativeInventory;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const Players = @import("players").players.Players;
const PlayerStates = @import("vanilla_player").player_states.PlayerStates;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const Input = @import("players").input.Input;
const Items = @import("vanilla_items").items.Items;
const EquipmentSlots = @import("vanilla_items").item_properties.EquipmentSlots;

pub const InventoryFixture = struct {
    definitions: definition_provider.Dependencies,
    service: *sessions.Service,
    input: *Input,
    players: *Players,
    player_states: *PlayerStates,
    world_border: *WorldBorder,
    ownership: *inventories.Inventories,
    items: *Items,
    menu: *PlayerInventory,
    menus: *InventoryMenus,
    creative: *CreativeInventory,
    bodies: *entities.Entities,
    dropped: *ItemEntities,

    pub fn location(self: InventoryFixture, kind: menu_click.Kind) crafting.Location {
        const player = self.players.records[0];
        return if (kind == .player)
            .{ .player = .{ .world = player.world, .position = player.position } }
        else
            .{ .block = .{ .world = player.world, .position = .{ .x = -33, .y = 64, .z = 18 } } };
    }

    pub fn init(allocator: std.mem.Allocator, store: *storage.Store, registry: *metrics.Registry, selected: []const sessions.Protocol) !InventoryFixture {
        const io = std.testing.io;
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const service = try sessions.Service.init(allocator, io, undefined, .{ .connections = 2, .pages = 2, .page_bytes = 65536, .credit_bytes = 128 * 1024, .protocols = selected });
        errdefer service.deinit();
        const input = try Input.init(allocator, .{ .sessions = service });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        // Players are entities: the space comes first.
        const bodies = try entities.Entities.init(allocator, io, .{}, .{ .metrics = registry, .storage = try store.openSpace("entities"), .record_workspaces = workspaces });
        const players = try Players.init(allocator, .{ .maximum = 2, .world = world }, .{
            .record_workspaces = workspaces,
            .sessions = service,
            .packets = undefined,
            .input = input,
            .storage = try store.openSpace("players"),
            .worlds = dimensions,
            .entities = bodies,
        });
        players.records[0] = .{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .loaded = true };
        try players.rebuildIndexes();
        const gameplay_definitions = try vanilla_content.prepare(allocator);
        const world_border = try WorldBorder.init(allocator, .{}, .{ .storage = try store.openSpace(WorldBorder.id), .worlds = dimensions, .dimensions = gameplay_definitions.dimensions, .players = players });
        const player_states = try PlayerStates.init(allocator, .{}, .{
            .record_workspaces = workspaces,
            .players = players,
            .input = input,
            .packets = undefined,
            .storage = try store.openSpace(PlayerStates.id),
            .worlds = dimensions,
            .vanilla_worlds = undefined,
            .world_border = world_border,
        });
        player_states.records[0] = .{ .uuid = 1, .gamemode = .creative };
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .definitions = gameplay_definitions.items, .inventories = ownership, .registry_identity = undefined });
        const dropped = try ItemEntities.init(allocator, io, .{}, .{
            .metrics = registry,
            .storage = try store.openSpace("drops"),
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
        });
        const menu = try PlayerInventory.init(allocator, .{}, .{
            .crafting = gameplay_definitions.crafting,
            .furnaces = gameplay_definitions.furnaces,
            .players = players,
            .player_states = player_states,
            .inventories = ownership,
            .items = items,
            .equipment = try EquipmentSlots.init(allocator, .{ .items = items, .enchantments = gameplay_definitions.enchantments }),
            .dropped = dropped,
        });
        const creative = try CreativeInventory.init(allocator, .{
            .inventory = menu,
            .input = input,
            .players = players,
            .player_states = player_states,
            .sessions = service,
            .packets = undefined,
            .inventories = ownership,
            .items = items,
        });
        const menus = try InventoryMenus.init(allocator, .{ .containers = undefined, .inventory = menu, .input = input, .players = players, .player_states = player_states, .inventories = ownership, .items = items, .packets = undefined, .sessions = service });
        // Items kept near the player come back into memory, as the item tick would bring them.
        try dropped.refresh(&.{.{ .world = world, .x = 0, .z = 0 }}, 2, entities.residency.NoColumns{});
        return .{ .definitions = gameplay_definitions, .service = service, .input = input, .players = players, .player_states = player_states, .world_border = world_border, .ownership = ownership, .items = items, .menu = menu, .menus = menus, .creative = creative, .bodies = bodies, .dropped = dropped };
    }
};
