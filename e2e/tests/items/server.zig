const std = @import("std");
const fixture = @import("../../src/fixture.zig");
const protocols = @import("protocols");
const vanilla = @import("vanilla");

const Dependencies = fixture.Context;
pub const settings: fixture.Settings = .{ .kind = .items, .players = .{ .gamemode = .survival, .spawn = .{ .x = 0.5, .y = 65, .z = 0.5 } } };

pub const Fixture = struct {
    items_created: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !Fixture {
        _ = allocator;
        _ = deps;
        return .{};
    }

    pub fn tick(self: *Fixture, deps: Dependencies) !void {
        for (deps.players.records, 0..) |*player, index| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.loaded) continue;

            for (deps.input.values(handle)) |event| {
                if (event != .command) continue;
                if (std.mem.eql(u8, event.command, "items_mine_setup")) {
                    if (!try deps.menus.give(index, "minecraft:iron_pickaxe", 1)) return error.ToolSetup;
                    try deps.chunks.setBlock(0, .{ .x = 4, .y = 65, .z = -2 }, protocols.registry.block_stone_default_state);
                    try deps.chunks.setBlock(0, .{ .x = 5, .y = 65, .z = -2 }, protocols.registry.block_stone_default_state);
                }

                if (std.mem.eql(u8, event.command, "items_create") and !self.items_created) {
                    self.items_created = true;
                    const bread = try deps.items.define("minecraft:bread");
                    _ = try deps.dropped.create(0, .{ 4.5, 69, 0.5 }, .{ 0, 0, 0 }, .{ .item = bread, .count = 8 });
                    _ = try deps.dropped.create(0, .{ 4.75, 69, 0.5 }, .{ 0, 0, 0 }, .{ .item = bread, .count = 9 });
                    std.log.info("event=items_created count=17", .{});
                }

                if (std.mem.eql(u8, event.command, "items_check")) {
                    var total: u32 = 0;

                    for (deps.players.records) |other| {
                        if (other.handle == null) continue;

                        for (9..46) |slot_index| {
                            const held = try deps.menus.deps.inventories.get(.{ .owner = other.uuid, .index = @intCast(slot_index) });

                            if (held.stack) |stack| total += stack.count;
                        }
                    }

                    var cursor: vanilla.ItemEntities.Cursor = .{};

                    while (cursor.more) for (try deps.dropped.scan(&cursor)) |row| {
                        if (row.metadata.alive) return error.ItemStillAlive;
                    };

                    if (total != 17 or deps.item_tick.merged != 1) return error.ItemConservation;
                    std.log.info("event=items_verified inventory={d} merged={d}", .{ total, deps.item_tick.merged });
                    deps.chat.system(handle, "Items verified");
                }
            }
        }
    }
};
