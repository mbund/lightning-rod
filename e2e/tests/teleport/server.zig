const std = @import("std");

const registry = protocols.registry;
const fixture = @import("../../src/fixture.zig");
const inventory_fixture = @import("../inventory/server.zig");
const protocols = @import("protocols");
const vanilla = @import("vanilla");

const commands = vanilla.commands;
pub const settings: fixture.Settings = .{
    .kind = .inventory,
    .players = inventory_fixture.settings.players,
    .worlds = 4,
    .teleport = .{ .enabled = true },
};

pub const Probe = struct {
    pub const id = "e2e:teleport";

    pub const Configuration = struct { enabled: bool };

    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *vanilla.Players,
        chunks: *vanilla.Chunks,
        menus: *vanilla.Menus,
        dropped: *vanilla.ItemEntities,
    };

    deps: Dependencies,
    isolated_item: u64 = 0,

    const WorldArgs = struct { world: enum(u32) { overworld = 0, nether = 1, end = 2, overworld_two = 7 } };

    const Isolation = struct { phase: enum { setup, move, verify } };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        if (config.enabled) {
            if (deps.players.deps.worlds.find("e2e:overworld_two")) |restored| {
                if (try deps.chunks.getBlock(restored.id, .{ .x = 10, .y = 64, .z = 10 }) != protocols.registry.block_stone_default_state)
                    return error.RuntimeWorldNotRestored;
                std.log.info("event=runtime_world_restored id={d}", .{restored.id});
            }

            _ = try deps.commands.register(self, commands.leaf(Probe, WorldArgs, .{
                .name = "testworld",
                .description = "Move Bob to a test dimension",
                .permission = &vanilla.TeleportCommands.permission,
                .handler = world,
                .arguments = .{ .world = .{} },
            }));
            _ = try deps.commands.register(self, commands.leaf(Probe, Isolation, .{
                .name = "testisolation",
                .description = "Verify world interaction boundaries",
                .permission = &vanilla.TeleportCommands.permission,
                .handler = isolation,
                .arguments = .{ .phase = .{} },
            }));
        }

        return self;
    }

    fn world(self: *Probe, _: commands.Context, args: WorldArgs) !void {
        for (self.deps.players.records) |*player| if (player.handle != null and std.mem.eql(u8, player.name[0..player.name_len], "bob")) {
            const block: u16 = switch (args.world) {
                .overworld => registry.block_grass_block_default_state,
                .nether => registry.block_netherrack_default_state,
                .end => registry.block_end_stone_default_state,
                .overworld_two => registry.block_stone_default_state,
            };
            const worlds = self.deps.players.deps.worlds;
            const defaults = self.deps.players.deps.vanilla_worlds;
            const world_id = switch (args.world) {
                .overworld => defaults.overworld,
                .nether => defaults.nether,
                .end => defaults.end,
                .overworld_two => try worlds.create(.{ .name = "e2e:overworld_two", .dimension = .overworld }),
            };
            if (args.world == .overworld_two) {
                if (world_id != try worlds.create(.{ .name = "e2e:overworld_two", .dimension = .overworld })) return error.UnstableWorldIdentity;

                if (worlds.create(.{ .name = "e2e:overworld_two", .dimension = .nether })) |_| return error.WorldIdentityReassigned else |err| if (err != error.WorldIdentityChanged) return err;

                if (worlds.create(.{ .name = "e2e:overflow", .dimension = .overworld })) |_| return error.WorldCapacityExceeded else |err| if (err != error.WorldCapacity) return err;
                if (worlds.find("e2e:overflow") != null or worlds.all().len != 4) return error.PartialWorldCreated;
                std.log.info("event=runtime_world_verified id={d} name=e2e:overworld_two", .{world_id});
            }

            try self.deps.chunks.setBlock(world_id, .{ .x = 10, .y = 64, .z = 10 }, block);
            try self.deps.players.teleport(player, world_id, .{ .x = 10.5, .y = 65, .z = 10.5 }, .{ .yaw = 35, .pitch = 0 });
            return;
        };
    }

    fn isolation(self: *Probe, context: commands.Context, args: Isolation) !void {
        const alice = self.deps.players.find(context.sender) orelse return error.PlayerNotReady;
        var bob: ?*vanilla.Players.Player = null;

        for (self.deps.players.records) |*player| if (player.handle != null and std.mem.eql(u8, player.name[0..player.name_len], "bob")) {
            bob = player;
        };

        const other = bob orelse return error.PlayerNotReady;

        switch (args.phase) {
            .setup => {
                try self.deps.chunks.setBlock(0, .{ .x = 10, .y = 64, .z = 11 }, registry.block_stone_default_state);
                try self.deps.players.teleport(alice, 0, .{ .x = 8.5, .y = 65, .z = 10.5 }, .{ .yaw = -90, .pitch = 30 });
                try self.deps.players.teleport(other, 0, .{ .x = 10.5, .y = 65, .z = 10.5 }, .{ .yaw = 0, .pitch = 60 });
                if (!try self.deps.menus.give(alice.handle.?.index, "minecraft:stone", 8)) return error.InventorySetup;
            },
            .move => {
                try self.deps.players.teleport(other, 1, other.position, other.rotation);
                const bread = (try self.deps.menus.deps.inventories.get(.{ .owner = alice.uuid, .index = 36 })).stack.?;
                self.isolated_item = try self.deps.dropped.create(1, .{ 8.5, 65, 10.5 }, @splat(0), .{ .item = bread.item, .count = 3 });
                var metadata = try self.deps.dropped.get(self.isolated_item);
                metadata.pickup_delay = 0;
                try self.deps.dropped.put(self.isolated_item, metadata);
            },
            .verify => {
                if (try self.deps.chunks.getBlock(0, .{ .x = 10, .y = 65, .z = 10 }) != registry.block_stone_default_state or try self.deps.chunks.getBlock(1, .{ .x = 10, .y = 65, .z = 10 }) != 0)
                    return error.CrossWorldPlacement;

                var metadata = try self.deps.dropped.get(self.isolated_item);
                if (!metadata.alive) return error.CrossWorldPickup;

                const body = (try self.deps.dropped.deps.entities.get(self.isolated_item)).?;
                const held = try self.deps.menus.deps.inventories.get(vanilla.ItemEntities.slot(body));
                if (held.stack == null or held.stack.?.count != 3) return error.CrossWorldPickup;
                if (!try self.deps.menus.deps.inventories.set(vanilla.ItemEntities.slot(body), held.revision, null)) return error.ItemCleanupFailed;
                try self.deps.dropped.retire(self.isolated_item, body, &metadata);
                try self.deps.chunks.setBlock(0, .{ .x = 10, .y = 65, .z = 10 }, 0);
                try self.deps.players.teleport(other, 0, other.position, other.rotation);
            },
        }

        context.reply(@tagName(args.phase));
    }
};
