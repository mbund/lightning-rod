const std = @import("std");
const container_menu = @import("container_menu.zig");
const entity_store = @import("world/entities.zig");
const geometry = @import("world/geometry.zig");
const input_store = @import("world/inputs.zig");
const living_entities = @import("living_entities.zig");
const player_store = @import("world/players.zig");
const Packets = @import("packet_writer.zig").Packets;
const world_identity = @import("world/identity.zig");
const world_dimensions = @import("world/dimensions.zig");
const world_generation = @import("world/generation.zig");
const world_store = @import("world/worlds.zig");

pub const Rotation = union(enum) {
    preserve,
    set: geometry.Rotation,
};

pub const Velocity = union(enum) {
    preserve,
    clear,
    set: geometry.Vec3,
};

pub const Destination = struct {
    world: world_identity.Handle,
    position: geometry.Vec3,
    rotation: Rotation = .preserve,
    velocity: Velocity = .clear,
};

pub const Teleportation = struct {
    pub const id = "lightning_rod:teleportation";

    worlds: *world_store.Worlds,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,
    containers: *player_store.Containers,
    inputs: *input_store.Inputs,

    pub fn create(
        allocator: std.mem.Allocator,
        worlds: *world_store.Worlds,
        players: *player_store.Players,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        containers: *player_store.Containers,
        inputs: *input_store.Inputs,
    ) !*Teleportation {
        const self = try allocator.create(Teleportation);
        self.* = .{
            .worlds = worlds,
            .players = players,
            .living = living,
            .items = items,
            .containers = containers,
            .inputs = inputs,
        };
        return self;
    }

    pub fn player(
        self: *Teleportation,
        outputs: *Packets,
        slot: u16,
        destination: Destination,
    ) !void {
        const result = try self.applyPlayer(slot, destination);
        if (result.closed_window) |window_id|
            outputs.container_closed(.{ .slot = slot, .window_id = window_id });
        if (result.world_changed) {
            outputs.player_world_changed(slot);
        } else {
            outputs.player_teleported(slot);
        }
    }

    const PlayerTransfer = struct {
        world_changed: bool,
        closed_window: ?i32,
    };

    fn applyPlayer(
        self: *Teleportation,
        slot: u16,
        destination: Destination,
    ) !PlayerTransfer {
        try self.validate(destination);
        self.players.assertSlot(slot);
        const player_record = &self.players.records[slot];
        if (player_record.state != .play) return error.PlayerNotInPlay;
        const world_changed = !player_record.world.eql(destination.world);
        const rotation = resolveRotation(player_record.rotation, destination.rotation);
        const closed_window = if (self.containers.open[slot].kind == .none)
            null
        else
            self.containers.open[slot].id;
        container_menu.close(self.players, self.containers, slot);
        self.players.teleport(slot, destination.world, destination.position, rotation);
        self.inputs.resetPlayerTransfer(slot);
        if (world_changed) player_record.play_join_terrain_ready = false;
        return .{ .world_changed = world_changed, .closed_window = closed_window };
    }

    pub fn livingEntity(
        self: *Teleportation,
        outputs: *Packets,
        handle: living_entities.Handle,
        destination: Destination,
    ) !void {
        const index = try self.applyLivingEntity(handle, destination);
        outputs.living_moved(index);
    }

    fn applyLivingEntity(
        self: *Teleportation,
        handle: living_entities.Handle,
        destination: Destination,
    ) !u16 {
        try self.validate(destination);
        if (!self.living.transfer(handle, destination.world, destination.position))
            return error.InvalidLivingEntity;
        const index = handle.index;
        const entities = &self.living.entities;
        const rotation = resolveRotation(.{
            .yaw = entities.yaw[index],
            .pitch = entities.pitch[index],
        }, destination.rotation);
        entities.yaw[index] = rotation.yaw;
        entities.pitch[index] = rotation.pitch;
        entities.body_yaw[index] = rotation.yaw;
        entities.head_yaw[index] = rotation.yaw;
        applyLivingVelocity(entities, index, destination.velocity);
        return index;
    }

    pub fn itemEntity(
        self: *Teleportation,
        outputs: *Packets,
        index: u16,
        destination: Destination,
    ) !void {
        _ = try self.applyItemEntity(index, destination);
        outputs.item_moved(index);
    }

    fn applyItemEntity(
        self: *Teleportation,
        index: u16,
        destination: Destination,
    ) !u16 {
        try self.validate(destination);
        if (!self.items.transfer(
            index,
            destination.world,
            destination.position,
            resolvedVelocity(destination.velocity),
        )) return error.InvalidItemEntity;
        return index;
    }

    fn validate(self: *const Teleportation, destination: Destination) !void {
        if (self.worlds.getConst(destination.world) == null) return error.InvalidWorld;
        if (!finite(destination.position)) return error.InvalidPosition;
        switch (destination.rotation) {
            .preserve => {},
            .set => |rotation| if (!std.math.isFinite(rotation.yaw) or
                !std.math.isFinite(rotation.pitch)) return error.InvalidRotation,
        }
        switch (destination.velocity) {
            .preserve, .clear => {},
            .set => |velocity| if (!finite(velocity)) return error.InvalidVelocity,
        }
    }
};

fn resolveRotation(current: geometry.Rotation, policy: Rotation) geometry.Rotation {
    return switch (policy) {
        .preserve => current,
        .set => |rotation| rotation,
    };
}

fn resolvedVelocity(policy: Velocity) ?geometry.Vec3 {
    return switch (policy) {
        .preserve => null,
        .clear => .{},
        .set => |velocity| velocity,
    };
}

fn applyLivingVelocity(entities: *living_entities.Pool, index: u16, policy: Velocity) void {
    const velocity = resolvedVelocity(policy) orelse return;
    entities.velocity_x[index] = velocity.x;
    entities.velocity_y[index] = velocity.y;
    entities.velocity_z[index] = velocity.z;
    entities.on_ground[index] = false;
}

fn finite(value: geometry.Vec3) bool {
    return std.math.isFinite(value.x) and
        std.math.isFinite(value.y) and
        std.math.isFinite(value.z);
}

const test_world_descriptions = [_]world_store.Description{
    .{
        .key = .{ .value = 1 },
        .name = "test:source",
        .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.Overworld),
        .generator = world_generation.Default.generatorId(world_generation.Overworld),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    },
    .{
        .key = .{ .value = 2 },
        .name = "test:target",
        .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.Overworld),
        .generator = world_generation.Default.generatorId(world_generation.Overworld),
        .seed = 2,
        .spawn_x = 0,
        .spawn_y = 80,
        .spawn_z = 0,
    },
};

test "player transfer atomically resets session-local state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lifecycle: @import("player_lifecycle.zig").Events = .{};
    const worlds = try world_store.Worlds.create(allocator, .{ .initial = &test_world_descriptions });
    _ = try world_dimensions.Vanilla.create(allocator, worlds);
    const players = try player_store.Players.create(allocator, &lifecycle);
    const living = try entity_store.LivingEntities.create(allocator);
    const items = try entity_store.ItemEntities.create(allocator);
    const containers = try player_store.Containers.create(allocator, &lifecycle);
    const inputs = try input_store.Inputs.create(allocator, &lifecycle);

    const source = worlds.find(.{ .value = 1 }).?;
    const target = worlds.find(.{ .value = 2 }).?;
    players.records[0] = .{ .state = .play, .world = source, .play_join_terrain_ready = true };
    containers.open[0] = .{ .kind = .chest, .id = 7 };
    inputs.movements[0].dirty = true;
    const teleports = try Teleportation.create(allocator, worlds, players, living, items, containers, inputs);
    const destination = Destination{ .world = target, .position = .{ .x = 1, .y = 80, .z = 2 } };
    const result = try teleports.applyPlayer(0, destination);

    try std.testing.expect(result.world_changed);
    try std.testing.expectEqual(@as(?i32, 7), result.closed_window);
    try std.testing.expect(players.records[0].world.eql(target));
    try std.testing.expectEqual(destination.position, players.records[0].position);
    try std.testing.expectEqual(@as(u64, 1), players.records[0].teleport_epoch);
    try std.testing.expect(!players.records[0].play_join_terrain_ready);
    try std.testing.expect(!inputs.movements[0].dirty);
    try std.testing.expectEqual(player_store.ContainerKind.none, containers.open[0].kind);
}

test "living and item transfers update world-local state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lifecycle: @import("player_lifecycle.zig").Events = .{};
    const worlds = try world_store.Worlds.create(allocator, .{ .initial = &test_world_descriptions });
    _ = try world_dimensions.Vanilla.create(allocator, worlds);
    const players = try player_store.Players.create(allocator, &lifecycle);
    const living = try entity_store.LivingEntities.create(allocator);
    const items = try entity_store.ItemEntities.create(allocator);
    const containers = try player_store.Containers.create(allocator, &lifecycle);
    const inputs = try input_store.Inputs.create(allocator, &lifecycle);
    const source = worlds.find(.{ .value = 1 }).?;
    const target = worlds.find(.{ .value = 2 }).?;
    const handle = try living.entities.spawn(.{
        .world = source,
        .entity_type = .zombie,
        .position = .{ .x = 0, .y = 64, .z = 0 },
        .uuid = 1,
        .random_seed = 1,
    });
    items.active[0] = true;
    items.worlds[0] = source;
    const teleports = try Teleportation.create(allocator, worlds, players, living, items, containers, inputs);
    const destination = Destination{
        .world = target,
        .position = .{ .x = 4, .y = 80, .z = 5 },
        .rotation = .{ .set = .{ .yaw = 90, .pitch = 10 } },
        .velocity = .{ .set = .{ .x = 1, .y = 2, .z = 3 } },
    };
    _ = try teleports.applyLivingEntity(handle, destination);
    _ = try teleports.applyItemEntity(0, destination);

    try std.testing.expect(living.entities.worlds[handle.index].eql(target));
    try std.testing.expectEqual(@as(f32, 90), living.entities.yaw[handle.index]);
    try std.testing.expectEqual(@as(f64, 2), living.entities.velocity_y[handle.index]);
    try std.testing.expect(items.worlds[0].eql(target));
    try std.testing.expectEqual(destination.position, items.position(0));
    try std.testing.expectEqual(@as(f64, 3), items.velocity_z[0]);
    try std.testing.expectEqual(entity_store.itemSpatialBucket(target, destination.position), items.bucket_indices[0]);
}

test "destination policies preserve or replace rotation" {
    const current = geometry.Rotation{ .yaw = 12, .pitch = -4 };
    try std.testing.expectEqual(current, resolveRotation(current, .preserve));
    try std.testing.expectEqual(
        geometry.Rotation{ .yaw = 90, .pitch = 15 },
        resolveRotation(current, .{ .set = .{ .yaw = 90, .pitch = 15 } }),
    );
}
