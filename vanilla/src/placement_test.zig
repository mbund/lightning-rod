const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const inventories = @import("inventories");
const worlds = @import("worlds");
const chunks = @import("chunks");
const sessions = @import("sessions");
const protocols = @import("protocols");
const game_data = @import("game_data");
const packets = @import("minecraft_packets");
const Items = @import("items.zig").Items;
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Input = @import("input.zig").Input;
const Placement = @import("placement.zig").Placement;
const BlockActions = @import("block_actions.zig").BlockActions;
const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;
const Doors = @import("doors.zig").Doors;
const selected_protocols = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};

const Fixture = struct {
    service: *sessions.Service,
    input: *Input,
    players: *Players,
    terrain: *chunks.Chunks,
    inventories: *inventories.Inventories,
    items: *Items,
    other_world: u32,

    fn init(allocator: std.mem.Allocator, store: *storage.Store, registry: *metrics.Registry) !Fixture {
        const io = std.testing.io;
        const service = try sessions.Service.init(allocator, io, undefined, .{ .connections = 2, .pages = 2, .page_bytes = 64 * 1024, .buffer_bytes = 128 * 1024, .protocols = &selected_protocols });
        const input = try Input.init(allocator, .{ .sessions = service });
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 2 }, .{ .storage = try store.openSpace("worlds") });
        const dimension: worlds.Worlds.Dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 };
        const world = try dimensions.create(.{ .name = "test:first", .dimension = dimension });
        const other_world = try dimensions.create(.{ .name = "test:second", .dimension = dimension });
        const players = try Players.init(allocator, .{ .maximum = 2, .world = world, .render_distance = 2 }, .{
            .record_workspaces = workspaces,
            .sessions = service,
            .packets = encoding,
            .input = input,
            .storage = try store.openSpace("players"),
            .worlds = dimensions,
            .vanilla_worlds = undefined,
        });
        for (players.records, 0..) |*player, index| player.* = .{
            .handle = .{ .index = @intCast(index), .generation = 1 },
            .uuid = index + 1,
            .world = world,
            .stage = .ready,
            .gamemode = .creative,
        };
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 64, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const menus = try PlayerInventory.init(allocator, .{
            .players = players,
            .inventories = ownership,
            .items = items,
            .equipment = undefined,
            .dropped = undefined,
        });
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 0, .cache_tiles = 8 }, .{
            .metrics = registry,
            .storage = try store.openSpace("chunks"),
            .record_workspaces = workspaces,
        });
        const blocks = try BlockSynchronization.init(allocator, io, .{
            .metrics = registry,
            .chunks = terrain,
            .players = players,
            .streaming = undefined,
            .sessions = service,
            .packets = encoding,
            .worlds = dimensions,
        }, .{ .delta_sections = 16, .queued_sections = 32 });
        const actions = try BlockActions.init(allocator, .{});
        _ = try Doors.init(allocator, .{ .actions = actions, .chunks = terrain, .players = players, .worlds = dimensions, .synchronization = blocks });
        _ = try Placement.init(allocator, .{
            .menus = menus,
            .players = players,
            .input = input,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .chunks = terrain,
            .blocks = blocks,
            .actions = actions,
        });
        return .{ .service = service, .input = input, .players = players, .terrain = terrain, .inventories = ownership, .items = items, .other_world = other_world };
    }

    fn place(self: *Fixture, position: chunks.Position, item: inventories.ItemId) !u16 {
        const player = &self.players.records[0];
        player.position = .{ .x = @as(f64, @floatFromInt(position.x)) - 1.5, .y = @floatFromInt(position.y), .z = @as(f64, @floatFromInt(position.z)) + 0.5 };
        self.players.rebuildIndexes();
        const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 };
        const held = try self.inventories.get(slot);
        try std.testing.expect(try self.inventories.set(slot, held.revision, .{ .item = item, .count = 64 }));
        try self.terrain.setBlock(player.world, position, 0);
        try self.terrain.setBlock(player.world, .{ .x = position.x, .y = position.y + 1, .z = position.z }, 0);
        try self.terrain.setBlock(player.world, .{ .x = position.x, .y = position.y - 1, .z = position.z }, game_data.registry.block_stone_default_state);
        var buffer: [128]u8 = undefined;
        const packet = try protocols.implementations[0].Protocol.play.toServer.write(&buffer).block_place();
        const hand = try packet.hand(0);
        const location = try hand.location(.{ .x = position.x, .y = @intCast(position.y - 1), .z = position.z });
        const face = try location.direction(1);
        const x = try face.cursorX(0.5);
        const y = try x.cursorY(1);
        const z = try y.cursorZ(0.5);
        const inside = try z.insideBlock(false);
        const border = try inside.worldBorderHit(false);
        const bytes = (try border.sequence(0)).finish();
        const incoming = [_][]const u8{bytes};
        const events = [_]sessions.Event{.{ .input = .{ .handle = player.handle.?, .protocol = protocols.implementations[0].protocol_number, .packets = .{ .packets = &incoming } } }};
        self.service.input_events = &events;
        defer self.service.input_events = &.{};
        try self.input.tick(std.testing.failing_allocator);
        return self.terrain.getBlock(player.world, position);
    }
};

test "block and door placement retain collision boundaries across chunk edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/placement", .{temporary.sub_path});
    var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 128 });
    defer registry.deinit();
    var fixture = try Fixture.init(allocator, &store, &registry);
    defer fixture.service.deinit();
    const stone = try fixture.items.define("minecraft:stone");
    const door = try fixture.items.define("minecraft:oak_door");
    failing.fail_index = failing.alloc_index;
    const epsilon = 0.0001;
    for ([_]i32{ 0, 15, 16, -1, -16 }) |coordinate| for ([_]inventories.ItemId{ stone, door }, 0..) |item, kind| {
        const position: chunks.Position = .{ .x = coordinate, .y = 65, .z = coordinate };
        const observer = &fixture.players.records[1];
        observer.handle = null;
        const state = try fixture.place(position, item);
        try std.testing.expect(state != 0);
        const shape = game_data.registry.collision_shapes[game_data.registry.block_state_collision_shape[state]];
        try std.testing.expectEqual(@as(usize, 1), shape.count);
        const box = game_data.registry.collision_boxes[shape.offset];
        const low_x: f64 = @as(f64, @floatFromInt(box.min_x)) / 64;
        const high_x: f64 = @as(f64, @floatFromInt(box.max_x)) / 64;
        const low_z: f64 = @as(f64, @floatFromInt(box.min_z)) / 64;
        const high_z: f64 = @as(f64, @floatFromInt(box.max_z)) / 64;
        const center_x = (low_x + high_x) / 2;
        const center_z = (low_z + high_z) / 2;
        const height: f64 = if (kind == 0) 1 else 2;
        const Case = struct { offset: [3]f64, blocked: bool, spectator: bool = false, elsewhere: bool = false, connected: bool = true };
        const cases = [_]Case{
            .{ .offset = .{ center_x, 0, center_z }, .blocked = true },
            .{ .offset = .{ low_x - 0.3 + epsilon, 0, center_z }, .blocked = true },
            .{ .offset = .{ low_x - 0.3 - epsilon, 0, center_z }, .blocked = false },
            .{ .offset = .{ high_x + 0.3 - epsilon, 0, center_z }, .blocked = true },
            .{ .offset = .{ high_x + 0.3 + epsilon, 0, center_z }, .blocked = false },
            .{ .offset = .{ center_x, 0, low_z - 0.3 + epsilon }, .blocked = true },
            .{ .offset = .{ center_x, 0, low_z - 0.3 - epsilon }, .blocked = false },
            .{ .offset = .{ center_x, 0, high_z + 0.3 - epsilon }, .blocked = true },
            .{ .offset = .{ center_x, 0, high_z + 0.3 + epsilon }, .blocked = false },
            .{ .offset = .{ center_x, height + epsilon, center_z }, .blocked = false },
            .{ .offset = .{ center_x, -1.8 + epsilon, center_z }, .blocked = true },
            .{ .offset = .{ center_x, -1.8 - epsilon, center_z }, .blocked = false },
            .{ .offset = .{ center_x, 0, center_z }, .blocked = false, .spectator = true },
            .{ .offset = .{ center_x, 0, center_z }, .blocked = false, .elsewhere = true },
            .{ .offset = .{ center_x, 0, center_z }, .blocked = false, .connected = false },
        };
        for (cases) |case| {
            observer.* = .{
                .handle = if (case.connected) .{ .index = 1, .generation = 1 } else null,
                .uuid = 2,
                .world = if (case.elsewhere) fixture.other_world else fixture.players.records[0].world,
                .gamemode = if (case.spectator) .spectator else .survival,
                .position = .{ .x = @as(f64, @floatFromInt(coordinate)) + case.offset[0], .y = 65 + case.offset[1], .z = @as(f64, @floatFromInt(coordinate)) + case.offset[2] },
            };
            const placed = try fixture.place(position, item);
            try std.testing.expectEqual(!case.blocked, placed != 0);
            const upper = try fixture.terrain.getBlock(fixture.players.records[0].world, .{ .x = coordinate, .y = 66, .z = coordinate });
            try std.testing.expectEqual(!case.blocked and kind == 1, upper != 0);
        }
    };
}
