const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const worlds = @import("worlds");
const entities = @import("entities");
const inventories = @import("inventories");
const sessions = @import("sessions");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const InventoryMenus = @import("inventory_menus.zig").InventoryMenus;
const CreativeInventory = @import("creative_inventory.zig").CreativeInventory;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
const Items = @import("items.zig").Items;
const EquipmentSlots = @import("item_properties.zig").EquipmentSlots;

pub const InventoryFixture = struct {
    service: *sessions.Service,
    input: *Input,
    players: *Players,
    ownership: *inventories.Inventories,
    items: *Items,
    menu: *PlayerInventory,
    creative: *CreativeInventory,
    bodies: *entities.Entities,
    dropped: *ItemEntities,

    pub fn init(allocator: std.mem.Allocator, store: *storage.Store, registry: *metrics.Registry, selected: []const sessions.Protocol) !InventoryFixture {
        const io = std.testing.io;
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const service = try sessions.Service.init(allocator, io, undefined, .{ .connections = 2, .pages = 2, .page_bytes = 65536, .buffer_bytes = 128 * 1024, .protocols = selected });
        errdefer service.deinit();
        const input = try Input.init(allocator, .{ .sessions = service });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const players = try Players.init(allocator, .{ .maximum = 2, .world = world }, .{
            .record_workspaces = workspaces,
            .sessions = service,
            .packets = undefined,
            .input = input,
            .storage = try store.openSpace("players"),
            .worlds = dimensions,
            .vanilla_worlds = undefined,
        });
        players.records[0] = .{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .loaded = true, .gamemode = .creative };
        players.rebuildIndexes();
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 16 }, .{ .metrics = registry, .storage = try store.openSpace("entities"), .record_workspaces = workspaces });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 32, .maximum = 8 }, .{
            .metrics = registry,
            .storage = try store.openSpace("drops"),
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
        });
        const menu = try PlayerInventory.init(allocator, .{
            .players = players,
            .inventories = ownership,
            .items = items,
            .equipment = try EquipmentSlots.init(allocator, .{ .items = items }),
            .dropped = dropped,
        });
        const creative = try CreativeInventory.init(allocator, .{
            .inventory = menu,
            .input = input,
            .players = players,
            .sessions = service,
            .packets = undefined,
            .inventories = ownership,
            .items = items,
        });
        _ = try InventoryMenus.init(allocator, .{ .containers = undefined, .inventory = menu, .input = input, .players = players, .inventories = ownership, .items = items, .packets = undefined, .sessions = service });
        return .{ .service = service, .input = input, .players = players, .ownership = ownership, .items = items, .menu = menu, .creative = creative, .bodies = bodies, .dropped = dropped };
    }
};
