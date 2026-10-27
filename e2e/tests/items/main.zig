const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const e2e = @import("e2e");
const sessions = @import("sessions");

pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = .survival }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = std.mem.eql(u8, args.fixture, "items_plaintext"), .reload_executable = "/proc/self/exe" });
}

const Probe = struct {
    pub const id = "e2e:items";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        chunks: *vanilla.Chunks,
        control: *e2e.Control,
        dropped: *vanilla.ItemEntities,
        inventories: *vanilla.Inventories,
        item_tick: *vanilla.ItemTick,
        items: *vanilla.Items,
        menus: *vanilla.PlayerInventory,
        mining: *vanilla.Mining,
        players: *vanilla.Players,
        reload: *vanilla.Reload,
    };
    deps: Dependencies,
    phase: enum { waiting, held, released } = .waiting,
    created_items: [2]u64 = undefined,
    hand_started: ?u64 = null,
    pick_started: ?u64 = null,
    hand_verified: bool = false,
    pick_verified: bool = false,
    // Finish packets are accepted at 70% progress to tolerate client/server tick drift.
    const minimum_hand_ticks = 150 * 7 / 10;
    const maximum_pickaxe_ticks = 30;
    const bread_counts = [_]u16{ 8, 9 };
    const bread_total = bread_counts[0] + bread_counts[1];
    const platform = .{ .x = 4, .y = 68, .z = 0 };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        deps.control.on(self, message);
        return self;
    }

    pub fn tick(self: *Probe) !void {
        for (self.deps.players.records, 0..) |player, index| {
            if (player.handle == null or !std.mem.eql(u8, player.name[0..player.name_len], "alice")) continue;
            const state = self.deps.mining.states[index];
            for (0..2) |tool| {
                const position = .{ .x = @as(i32, if (tool == 0) 4 else 5), .y = @as(i32, 65), .z = @as(i32, -2) };
                const started = if (tool == 0) &self.hand_started else &self.pick_started;
                const verified = if (tool == 0) &self.hand_verified else &self.pick_verified;
                if (verified.*) continue;
                if (state.active and state.position.x == position.x and state.position.y == position.y and state.position.z == position.z)
                    started.* = state.started;
                if (started.*) |started_tick| {
                    if (try self.deps.chunks.getBlock(player.world, .{ .x = position.x, .y = position.y, .z = position.z }) != 0) continue;
                    const elapsed = self.deps.players.ticks - started_tick + 1;
                    if (tool == 0 and elapsed < minimum_hand_ticks) return error.HandMiningTooFast;
                    if (tool == 1 and elapsed > maximum_pickaxe_ticks) return error.PickaxeMiningTooSlow;
                    verified.* = true;
                    try self.deps.control.broadcast(if (tool == 0) "Hand mining verified" else "Pickaxe mining verified");
                }
            }
        }
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        const index = handle.index;
        const player = &self.deps.players.records[index];
        if (player.stage != .ready or !player.loaded) return .unhandled;
        if (std.mem.eql(u8, text, "items_place_setup")) {
            if (!try self.deps.menus.give(index, "minecraft:dirt", 8)) return error.PlacementSetup;
        } else if (std.mem.eql(u8, text, "items_reload")) {
            if (try self.deps.chunks.getBlock(player.world, .{ .x = 3, .y = 65, .z = -1 }) != protocols.registry.block_dirt_default_state)
                return error.PlacementNotAuthoritative;
            try self.deps.reload.stage("e2e:survival");
        } else if (std.mem.eql(u8, text, "items_mine_setup")) {
            if (!try self.deps.menus.give(index, "minecraft:iron_pickaxe", 1)) return error.ToolSetup;
            try self.deps.chunks.setBlock(0, .{ .x = 4, .y = 65, .z = -2 }, protocols.registry.block_stone_default_state);
            try self.deps.chunks.setBlock(0, .{ .x = 5, .y = 65, .z = -2 }, protocols.registry.block_stone_default_state);
        } else if (std.mem.eql(u8, text, "items_create")) {
            if (self.phase != .waiting) return error.UnexpectedItemsPhase;
            self.phase = .held;
            const bread = try self.deps.items.define("minecraft:bread");
            // Hold the starting state until both clients have observed it.
            try self.deps.chunks.setBlock(0, .{ .x = platform.x, .y = platform.y, .z = platform.z }, protocols.registry.block_stone_default_state);
            self.created_items[0] = try self.deps.dropped.create(0, .{ 4.5, 69, 0.5 }, .{ 0, 0, 0 }, .{ .item = bread, .count = bread_counts[0] });
            self.created_items[1] = try self.deps.dropped.create(0, .{ 4.75, 69, 0.5 }, .{ 0, 0, 0 }, .{ .item = bread, .count = bread_counts[1] });
            for (self.created_items) |entity| try self.deps.dropped.put(entity, .{ .pickup_delay = std.math.maxInt(i16) });
            std.log.info("event=items_created count={d}", .{bread_total});
        } else if (std.mem.eql(u8, text, "items_release")) {
            if (self.phase != .held) return error.UnexpectedItemsPhase;
            self.phase = .released;
            for (self.created_items) |entity| {
                var metadata = try self.deps.dropped.get(entity);
                metadata.pickup_delay = 0;
                metadata.revision += 1;
                try self.deps.dropped.put(entity, metadata);
            }
            try self.deps.chunks.setBlock(0, .{ .x = platform.x, .y = platform.y, .z = platform.z }, comptime protocols.registry.blockStateId("minecraft:air").?);
        } else if (std.mem.eql(u8, text, "items_check")) {
            if (self.phase != .released) return error.ItemsNotReleased;
            var total: u32 = 0;

            for (self.deps.players.records) |other| {
                if (other.handle == null) continue;

                for (9..46) |slot_index| {
                    const held = try self.deps.inventories.get(.{ .owner = other.uuid, .index = @intCast(slot_index) });

                    if (held.stack) |stack| {
                        const item = try self.deps.items.kind(stack);
                        if (item == @as(u32, @intCast(protocols.registry.itemId("minecraft:bread").?))) total += stack.count;
                    }
                }
            }

            var cursor: vanilla.ItemEntities.Cursor = .{};

            while (cursor.more) for (try self.deps.dropped.scan(&cursor)) |row| {
                if (row.metadata.alive) return error.ItemStillAlive;
            };

            if (total != bread_total or self.deps.item_tick.merged != 1) return error.ItemConservation;
            std.log.info("event=items_verified inventory={d} merged={d}", .{ total, self.deps.item_tick.merged });
            try self.deps.control.send(handle, "Items verified");
        } else return .unhandled;
        return .handled;
    }
};
