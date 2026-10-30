const std = @import("std");
const vanilla = @import("vanilla");
const game_data = @import("game_data");
const sessions = @import("sessions");
const wire = @import("wire_1_21_5");

pub const StormStick = struct {
    pub const id = "example:storm_stick";
    pub const Configuration = struct { maximum_strikes: usize = 8 };
    pub const Dependencies = struct { enchantments: *vanilla.Enchantments.Registry, players: *vanilla.Players, chunks: *vanilla.Chunks, packets: *vanilla.Packets, entities: *vanilla.Entities };
    const Strike = struct { entity: vanilla.EntityId = 0, expires: u64 = 0, body: vanilla.EntityState = undefined };
    deps: Dependencies,
    strikes: []Strike,
    known: []u32,
    targets: []sessions.Service.Target,
    deliveries: []sessions.Service.Delivery,
    casts: u64 = 0,
    last: ?vanilla.raycast.Hit = null,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*StormStick {
        if (configuration.maximum_strikes == 0) return error.InvalidConfiguration;
        const self = try allocator.create(StormStick);
        self.* = .{
            .deps = deps,
            .strikes = try allocator.alloc(Strike, configuration.maximum_strikes),
            .known = try allocator.alloc(u32, try std.math.mul(usize, configuration.maximum_strikes, deps.players.records.len)),
            .targets = try allocator.alloc(sessions.Service.Target, deps.players.records.len),
            .deliveries = try allocator.alloc(sessions.Service.Delivery, deps.players.records.len),
        };
        @memset(self.strikes, .{});
        @memset(self.known, 0);
        try deps.enchantments.addEnchantments(&.{.{
            .name = "example:storm_calling",
            .description = "Storm Calling",
            .supported_items = &.{"minecraft:stick"},
            .effects = .{ .slots = .{ .mainhand = true, .offhand = true }, .on_use = &.{vanilla.enchantment_effects.UseBinding.bind(StormStick, self, cast)} },
        }});
        return self;
    }

    fn cast(self: *StormStick, context: *const vanilla.enchantment_effects.UseContext) !vanilla.item_actions.Result {
        if (context.action.item.kind != game_data.registry.itemId("minecraft:stick").?) return .pass;
        const player = context.action.player;
        const hit = try vanilla.raycast.trace(self.deps.chunks, player.world, .{ .x = player.position.x, .y = player.position.y + if (player.flags.sneaking) @as(f64, 1.27) else @as(f64, 1.62), .z = player.position.z }, vanilla.raycast.direction(player.rotation), 64) orelse return .pass;
        const index = for (self.strikes, 0..) |strike, index| {
            if (strike.entity == 0) break index;
        } else return .denied;
        const entity = self.deps.entities.next_id;
        if (entity > std.math.maxInt(i32)) return error.EntityIdExhausted;
        const body: vanilla.EntityState = .{ .uuid = @as(u128, entity) | (@as(u128, 0x5702) << 64), .kind = @intCast(game_data.registry.entityId("minecraft:lightning_bolt").?), .world = player.world, .position = .{ hit.position.x, hit.position.y, hit.position.z } };
        const created = try self.deps.entities.reserveIds(1);
        std.debug.assert(created == entity);
        self.strikes[index] = .{ .entity = entity, .expires = self.deps.players.ticks + 40, .body = body };
        self.casts += 1;
        self.last = hit;
        return .applied;
    }

    pub fn tick(self: *StormStick) !void {
        for (self.strikes, 0..) |*strike, index| {
            if (strike.entity == 0) continue;
            const known = self.known[index * self.deps.players.records.len ..][0..self.deps.players.records.len];
            const expired = self.deps.players.ticks >= strike.expires;
            var count: usize = 0;
            for (self.deps.players.activeSlots()) |at| {
                const player = self.deps.players.records[at];
                const handle = player.handle orelse continue;
                if (known[at] != handle.generation) known[at] = 0;
                if (player.stage != .ready) {
                    known[at] = 0;
                    continue;
                }
                if (expired) {
                    if (known[at] == 0) continue;
                } else {
                    if (known[at] != 0 or player.world != strike.body.world or @abs(player.position.x - strike.body.position[0]) > 128 or @abs(player.position.z - strike.body.position[2]) > 128) continue;
                }
                self.targets[count] = .{ .handle = handle, .protocol = player.protocol };
                count += 1;
            }
            const network_id = -@as(i32, @intCast(strike.entity));
            if (expired) try self.deps.packets.fanout(remove, self.targets[0..count], .{network_id}, 32, self.deliveries[0..count]) else try self.deps.packets.fanout(vanilla.entity_packets.spawn, self.targets[0..count], .{ network_id, strike.body }, 128, self.deliveries[0..count]);
            var pending = false;
            for (self.targets[0..count], self.deliveries[0..count]) |target, delivery| switch (delivery) {
                .queued => known[target.handle.index] = if (expired) 0 else target.handle.generation,
                .unsupported => return error.UnsupportedLightningProtocol,
                .closed => known[target.handle.index] = 0,
                .backpressured => pending = true,
            };
            if (expired and !pending) {
                strike.* = .{};
                @memset(known, 0);
            }
        }
    }

    fn remove(packet: wire.play.toClient.packet_entity_destroy.Writer, network_id: i32) ![]u8 {
        return (try (try (try packet.entityIds(1)).element(network_id)).finish()).finish();
    }
};
