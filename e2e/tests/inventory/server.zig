const std = @import("std");
const fixture = @import("../../src/fixture.zig");
const vanilla = @import("vanilla");

const Dependencies = fixture.Context;
pub const settings: fixture.Settings = .{
    .kind = .inventory,
    .players = .{ .gamemode = .survival, .spawn = .{ .x = 0.5, .y = 65, .z = 0.5 } },
};

pub const Fixture = struct {
    given: []u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !Fixture {
        const given = try allocator.alloc(u32, deps.players.records.len);
        @memset(given, 0);
        return .{ .given = given };
    }

    pub fn tick(self: *Fixture, deps: Dependencies) !void {
        for (deps.players.deps.sessions.input_events) |event| {
            if (event == .joined and event.joined.cause == .reload)
                self.given[event.joined.handle.index] = event.joined.handle.generation;
        }

        for (deps.players.records, self.given, 0..) |*player, *given, index| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.loaded or given.* != 0) continue;

            const slot = try deps.menus.deps.inventories.get(.{ .owner = player.uuid, .index = 36 });
            if (slot.stack == null and !try deps.menus.give(index, "minecraft:bread", 17)) return error.InventorySetup;
            given.* = handle.generation;
        }
    }
};
