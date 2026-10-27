const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const vanilla = @import("vanilla");
const sessions = @import("sessions");

pub fn main(init: std.process.Init) !void {
    const operators = e2e.profile.aliceOperator();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = .survival }),
            lightning_rod.plugin.configured(vanilla.Worlds, .{ .maximum = 4 }),
            lightning_rod.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = &operators }),
        }),
        lightning_rod.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

const Probe = struct {
    pub const id = "e2e:teleport";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        control: *e2e.Control,
        players: *vanilla.Players,
        chunks: *vanilla.Chunks,
        menus: *vanilla.PlayerInventory,
        dropped: *vanilla.ItemEntities,
        worlds: *vanilla.Worlds,
        vanilla_worlds: *vanilla.VanillaWorlds,
        inventories: *vanilla.Inventories,
        entities: *vanilla.Entities,
    };

    deps: Dependencies,
    isolated_item: u64 = 0,

    const World = enum(u32) {
        overworld = 0,
        nether = 1,
        end = 2,
        overworld_two = 7,
    };

    const Isolation = enum {
        setup,
        move,
        verify,
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        if (deps.worlds.find("e2e:overworld_two")) |restored| {
            if (try deps.chunks.getBlock(restored.id, .{ .x = 10, .y = 64, .z = 10 }) != protocols.registry.block_stone_default_state)
                return error.RuntimeWorldNotRestored;
            std.log.info("event=runtime_world_restored id={d}", .{restored.id});
        }

        deps.control.on(self, message);

        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.startsWith(u8, text, "testworld ")) {
            const value = std.meta.stringToEnum(World, text[10..]) orelse return error.InvalidFixtureWorld;
            try self.world(value);
        } else if (std.mem.startsWith(u8, text, "testisolation ")) {
            const value = std.meta.stringToEnum(Isolation, text[14..]) orelse return error.InvalidFixtureIsolation;
            try self.isolation(handle, value);
        } else return .unhandled;
        return .handled;
    }

    fn world(self: *Probe, destination: World) !void {
        for (self.deps.players.records) |*player| if (player.handle != null and std.mem.eql(u8, player.name[0..player.name_len], "bob")) {
            const block: u16 = switch (destination) {
                .overworld => protocols.registry.block_grass_block_default_state,
                .nether => protocols.registry.block_netherrack_default_state,
                .end => protocols.registry.block_end_stone_default_state,
                .overworld_two => protocols.registry.block_stone_default_state,
            };
            const worlds = self.deps.worlds;
            const defaults = self.deps.vanilla_worlds;
            const world_id = switch (destination) {
                .overworld => defaults.overworld,
                .nether => defaults.nether,
                .end => defaults.end,
                .overworld_two => try worlds.create(.{ .name = "e2e:overworld_two", .dimension = vanilla.VanillaWorlds.dimensions.overworld }),
            };
            if (destination == .overworld_two) {
                if (world_id != try worlds.create(.{ .name = "e2e:overworld_two", .dimension = vanilla.VanillaWorlds.dimensions.overworld })) return error.UnstableWorldIdentity;

                if (worlds.create(.{ .name = "e2e:overworld_two", .dimension = vanilla.VanillaWorlds.dimensions.nether })) |_| return error.WorldIdentityReassigned else |err| if (err != error.WorldIdentityChanged) return err;

                if (worlds.create(.{ .name = "e2e:overflow", .dimension = vanilla.VanillaWorlds.dimensions.overworld })) |_| return error.WorldCapacityExceeded else |err| if (err != error.WorldCapacity) return err;
                if (worlds.find("e2e:overflow") != null or worlds.all().len != 4) return error.PartialWorldCreated;
                std.log.info("event=runtime_world_verified id={d} name=e2e:overworld_two", .{world_id});
            }

            try self.deps.chunks.setBlock(world_id, .{ .x = 10, .y = 64, .z = 10 }, block);
            try self.deps.players.teleport(player, world_id, .{ .x = 10.5, .y = 65, .z = 10.5 }, .{ .yaw = 35, .pitch = 0 });
            std.log.info("event=test_world_teleport world={d} name={s}", .{ world_id, worlds.get(world_id).?.name });
            return;
        };
    }

    fn isolation(self: *Probe, handle: sessions.Handle, phase: Isolation) !void {
        const alice = &self.deps.players.records[handle.index];
        var bob: ?*vanilla.Players.Player = null;

        for (self.deps.players.records) |*player| if (player.handle != null and std.mem.eql(u8, player.name[0..player.name_len], "bob")) {
            bob = player;
        };

        const other = bob orelse return error.PlayerNotReady;

        switch (phase) {
            .setup => {
                try self.deps.chunks.setBlock(0, .{ .x = 10, .y = 64, .z = 11 }, protocols.registry.block_stone_default_state);
                try self.deps.players.teleport(alice, 0, .{ .x = 8.5, .y = 65, .z = 10.5 }, .{ .yaw = -90, .pitch = 30 });
                try self.deps.players.teleport(other, 0, .{ .x = 10.5, .y = 65, .z = 10.5 }, .{ .yaw = 0, .pitch = 60 });
                if (!try self.deps.menus.give(alice.handle.?.index, "minecraft:stone", 8)) return error.InventorySetup;
            },
            .move => {
                try self.deps.players.teleport(other, 1, other.position, other.rotation);
                const bread = (try self.deps.inventories.get(.{ .owner = alice.uuid, .index = 36 })).stack.?;
                self.isolated_item = try self.deps.dropped.create(1, .{ 8.5, 65, 10.5 }, @splat(0), .{ .item = bread.item, .count = 3 });
                var metadata = try self.deps.dropped.get(self.isolated_item);
                metadata.pickup_delay = 0;
                try self.deps.dropped.put(self.isolated_item, metadata);
            },
            .verify => {
                if (try self.deps.chunks.getBlock(0, .{ .x = 10, .y = 65, .z = 10 }) != protocols.registry.block_stone_default_state or try self.deps.chunks.getBlock(1, .{ .x = 10, .y = 65, .z = 10 }) != 0)
                    return error.CrossWorldPlacement;

                var metadata = try self.deps.dropped.get(self.isolated_item);
                if (!metadata.alive) return error.CrossWorldPickup;

                const body = (try self.deps.entities.get(self.isolated_item)).?;
                const held = try self.deps.inventories.get(vanilla.ItemEntities.slot(body));
                if (held.stack == null or held.stack.?.count != 3) return error.CrossWorldPickup;
                if (!try self.deps.inventories.set(vanilla.ItemEntities.slot(body), held.revision, null)) return error.ItemCleanupFailed;
                try self.deps.dropped.retire(self.isolated_item, body, &metadata);
                try self.deps.chunks.setBlock(0, .{ .x = 10, .y = 65, .z = 10 }, 0);
                try self.deps.players.teleport(other, 0, other.position, other.rotation);
            },
        }

        try self.deps.control.send(handle, @tagName(phase));
    }
};
