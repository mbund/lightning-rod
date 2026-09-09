const std = @import("std");
const preallocated = @import("preallocated");
const vanilla_random = @import("java_random.zig");
const diagnostics = @import("diagnostics.zig");
const world_identity = @import("world/identity.zig");

pub const cache_line_size = 64;
const test_world = world_identity.Handle{ .index = 0, .generation = 1 };

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,
};

pub const no_vehicle = Handle{ .index = std.math.maxInt(u16), .generation = 0 };

pub const EntityType = enum(u8) {
    zombie,
    zombified_piglin,
    turtle,
    cow,
    pig,
    chicken,
};

pub const Target = union(enum) {
    none,
    player: u16,
    living: Handle,
};

pub const Position = extern struct {
    x: f64,
    y: f64,
    z: f64,
};

pub const Velocity = extern struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
};

pub const EquipmentStack = extern struct {
    item_id: i32 = 0,
    damage: u16 = 0,
    count: u8 = 0,
};

pub const Spawn = struct {
    world: world_identity.Handle,
    entity_type: EntityType,
    position: Position,
    velocity: Velocity = .{},
    yaw: f32 = 0,
    pitch: f32 = 0,
    uuid: u128,
    random_seed: u64,
    baby: bool = false,
    persistent: bool = false,
};

pub const Entity = struct {
    handle: Handle,
    world: world_identity.Handle,
    entity_type: EntityType,
    entity_id: i32,
    uuid: u128,
    position: Position,
    velocity: Velocity,
    yaw: f32,
    pitch: f32,
    body_yaw: f32,
    head_yaw: f32,
    health: f32,
    fire_ticks: i32,
    despawn_counter: u32,
    target: Target,
    vehicle: ?Handle,
    baby: bool,
    breeding_age: i32,
    love_ticks: u16,
    persistent: bool,
    on_ground: bool,
    age: u32,
    target_goal_running: bool,
    melee_goal_running: bool,
    attacking: bool,
};

pub const Pool = struct {
    pub const Configuration = struct {
        maximum_entities: usize = 512,
        first_entity_id: i32,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_entities == 0 or self.maximum_entities >= std.math.maxInt(u16)) return error.InvalidLivingEntityCapacity;
        }
    };

    worlds: []align(cache_line_size) world_identity.Handle = &.{},
    position_x: []align(cache_line_size) f64 = &.{},
    position_y: []align(cache_line_size) f64 = &.{},
    position_z: []align(cache_line_size) f64 = &.{},
    velocity_x: []align(cache_line_size) f64 = &.{},
    velocity_y: []align(cache_line_size) f64 = &.{},
    velocity_z: []align(cache_line_size) f64 = &.{},
    yaw: []align(cache_line_size) f32 = &.{},
    pitch: []align(cache_line_size) f32 = &.{},
    body_yaw: []align(cache_line_size) f32 = &.{},
    head_yaw: []align(cache_line_size) f32 = &.{},
    health: []align(cache_line_size) f32 = &.{},
    max_health: []align(cache_line_size) f32 = &.{},
    last_damage_taken: []align(cache_line_size) f32 = &.{},
    movement_speed: []align(cache_line_size) f64 = &.{},
    attack_damage: []align(cache_line_size) f64 = &.{},
    follow_range: []align(cache_line_size) f64 = &.{},
    armor: []align(cache_line_size) f64 = &.{},
    armor_toughness: []align(cache_line_size) f64 = &.{},
    fire_ticks: []align(cache_line_size) i32 = &.{},
    despawn_counter: []align(cache_line_size) u32 = &.{},
    entity_ids: []align(cache_line_size) i32 = &.{},
    generations: []align(cache_line_size) u16 = &.{},
    entity_types: []align(cache_line_size) EntityType = &.{},
    uuids: []align(cache_line_size) u128 = &.{},
    targets: []align(cache_line_size) Target = &.{},
    vehicles: []align(cache_line_size) Handle = &.{},
    restored_vehicle_uuids: []align(cache_line_size) u128 = &.{},
    active: []align(cache_line_size) bool = &.{},
    baby: []align(cache_line_size) bool = &.{},
    jockey_candidate: []align(cache_line_size) bool = &.{},
    breeding_age: []align(cache_line_size) i32 = &.{},
    love_ticks: []align(cache_line_size) u16 = &.{},
    loving_player: []align(cache_line_size) u16 = &.{},
    passive_target_player: []align(cache_line_size) u16 = &.{},
    mate_index: []align(cache_line_size) u16 = &.{},
    mate_ticks: []align(cache_line_size) u8 = &.{},
    wander_cooldown: []align(cache_line_size) u16 = &.{},
    panic_ticks: []align(cache_line_size) u8 = &.{},
    persistent: []align(cache_line_size) bool = &.{},
    random: []align(cache_line_size) vanilla_random.Random = &.{},
    on_ground: []align(cache_line_size) bool = &.{},
    jump_requested: []align(cache_line_size) bool = &.{},
    pose_dirty: []align(cache_line_size) bool = &.{},
    metadata_dirty: []align(cache_line_size) bool = &.{},
    age: []align(cache_line_size) u32 = &.{},
    ambient_sound_chance: []align(cache_line_size) i32 = &.{},
    target_goal_running: []align(cache_line_size) bool = &.{},
    target_unseen_selector_ticks: []align(cache_line_size) u8 = &.{},
    melee_goal_running: []align(cache_line_size) bool = &.{},
    attacking: []align(cache_line_size) bool = &.{},
    hand_swinging: []align(cache_line_size) bool = &.{},
    hand_swing_ticks: []align(cache_line_size) i8 = &.{},
    melee_goal_ticks: []align(cache_line_size) u32 = &.{},
    melee_last_update_time: []align(cache_line_size) u64 = &.{},
    melee_target_x: []align(cache_line_size) f64 = &.{},
    melee_target_y: []align(cache_line_size) f64 = &.{},
    melee_target_z: []align(cache_line_size) f64 = &.{},
    melee_update_countdown: []align(cache_line_size) i32 = &.{},
    attack_cooldown: []align(cache_line_size) i32 = &.{},
    time_until_regen: []align(cache_line_size) i32 = &.{},
    death_time: []align(cache_line_size) u8 = &.{},
    dead: []align(cache_line_size) bool = &.{},
    can_pick_up_loot: []align(cache_line_size) bool = &.{},
    can_break_doors: []align(cache_line_size) bool = &.{},
    leader: []align(cache_line_size) bool = &.{},
    reinforcement_chance: []align(cache_line_size) f64 = &.{},
    equipment: []align(cache_line_size) [6]EquipmentStack = &.{},
    equipment_drop_guaranteed: []align(cache_line_size) [6]bool = &.{},
    active_indices: []align(cache_line_size) u16 = &.{},
    active_positions: []align(cache_line_size) u16 = &.{},
    free_indices: []align(cache_line_size) u16 = &.{},
    active_count: usize = 0,
    free_count: usize = 0,
    initialized: bool = false,
    first_entity_id: i32 = 0,

    pub fn allocate(self: *Pool, allocator: std.mem.Allocator, configuration: Configuration) !void {
        try configuration.validate();
        self.* = .{};
        inline for (@typeInfo(Pool).@"struct".fields) |field| {
            if (@typeInfo(field.type) == .pointer and @typeInfo(field.type).pointer.size == .slice) {
                const Child = @typeInfo(field.type).pointer.child;
                @field(self, field.name) = try preallocated.alignedAlloc(Child, allocator, .@"64", configuration.maximum_entities);
            }
        }
        self.first_entity_id = configuration.first_entity_id;
        self.initInPlace();
    }

    pub fn initInPlace(self: *Pool) void {
        @memset(self.active, false);
        @memset(self.generations, 1);
        @memset(self.vehicles, no_vehicle);
        @memset(self.restored_vehicle_uuids, 0);
        self.free_count = self.active.len;
        for (0..self.active.len) |position| {
            self.free_indices[position] = @intCast(self.active.len - 1 - position);
        }
        self.initialized = true;
        self.assertInvariants();
    }

    pub fn spawn(self: *Pool, value: Spawn) !Handle {
        self.assertInvariants();
        if (self.free_count == 0) return error.LivingEntityCapacity;

        const before_active = self.active_count;
        const before_free = self.free_count;
        self.free_count -= 1;
        const index = self.free_indices[self.free_count];
        std.debug.assert(!self.active[index]);
        const handle = Handle{ .index = index, .generation = self.generations[index] };
        self.initializeSpawn(index, value);
        self.initializeZombie(index, value);
        self.active[index] = true;
        self.active_indices[self.active_count] = index;
        self.active_positions[index] = @intCast(self.active_count);
        self.active_count += 1;
        std.debug.assert(self.active_count == before_active + 1);
        std.debug.assert(self.free_count + 1 == before_free);
        std.debug.assert(self.isAlive(handle));
        self.assertInvariants();
        return handle;
    }

    fn initializeSpawn(self: *Pool, index: u16, value: Spawn) void {
        std.debug.assert(world_identity.valid(value.world));
        self.worlds[index] = value.world;
        self.entity_types[index] = value.entity_type;
        self.entity_ids[index] = self.entityId(index);
        self.uuids[index] = value.uuid;
        self.position_x[index] = value.position.x;
        self.position_y[index] = value.position.y;
        self.position_z[index] = value.position.z;
        self.velocity_x[index] = value.velocity.x;
        self.velocity_y[index] = value.velocity.y;
        self.velocity_z[index] = value.velocity.z;
        self.yaw[index] = value.yaw;
        self.pitch[index] = value.pitch;
        self.body_yaw[index] = value.yaw;
        self.head_yaw[index] = value.yaw;
        self.fire_ticks[index] = 0;
        self.despawn_counter[index] = 0;
        self.targets[index] = .none;
        self.vehicles[index] = no_vehicle;
        self.restored_vehicle_uuids[index] = 0;
        self.baby[index] = value.baby;
        self.jockey_candidate[index] = false;
        self.breeding_age[index] = if (value.baby) -24_000 else 0;
        self.love_ticks[index] = 0;
        self.loving_player[index] = std.math.maxInt(u16);
        self.passive_target_player[index] = std.math.maxInt(u16);
        self.mate_index[index] = std.math.maxInt(u16);
        self.mate_ticks[index] = 0;
        self.wander_cooldown[index] = 0;
        self.panic_ticks[index] = 0;
        self.persistent[index] = value.persistent;
        self.random[index].setSeed(value.random_seed);
        self.initializeBehavior(index);
        self.applyTypeDefaults(index, value.entity_type, value.baby);
        self.reinforcement_chance[index] = 0;
        self.can_pick_up_loot[index] = false;
        self.can_break_doors[index] = false;
        self.leader[index] = false;
    }

    fn initializeBehavior(self: *Pool, index: u16) void {
        self.on_ground[index] = false;
        self.jump_requested[index] = false;
        self.pose_dirty[index] = false;
        self.metadata_dirty[index] = false;
        self.age[index] = 0;
        self.ambient_sound_chance[index] = 0;
        self.target_goal_running[index] = false;
        self.target_unseen_selector_ticks[index] = 0;
        self.melee_goal_running[index] = false;
        self.attacking[index] = false;
        self.hand_swinging[index] = false;
        self.hand_swing_ticks[index] = 0;
        self.melee_goal_ticks[index] = 0;
        self.melee_last_update_time[index] = 0;
        self.melee_target_x[index] = 0;
        self.melee_target_y[index] = 0;
        self.melee_target_z[index] = 0;
        self.melee_update_countdown[index] = 0;
        self.attack_cooldown[index] = 0;
        self.last_damage_taken[index] = 0;
        self.armor_toughness[index] = 0;
        self.time_until_regen[index] = 0;
        self.death_time[index] = 0;
        self.dead[index] = false;
        self.equipment[index] = [_]EquipmentStack{.{}} ** 6;
        self.equipment_drop_guaranteed[index] = [_]bool{false} ** 6;
    }

    fn initializeZombie(self: *Pool, index: u16, value: Spawn) void {
        if (value.entity_type != .zombie) return;
        var spawn_random = vanilla_random.Random.init(value.random_seed);
        self.reinforcement_chance[index] = spawn_random.nextDouble() * 0.10000000149011612;
        self.can_pick_up_loot[index] = spawn_random.nextFloat() < 0.55;
        self.can_break_doors[index] = spawn_random.nextFloat() < 0.1;
        self.leader[index] = spawn_random.nextFloat() < 0.05;
        var jockey_random = vanilla_random.Random.init(value.random_seed ^ 0x6c6176615f636869);
        self.jockey_candidate[index] = value.baby and jockey_random.nextFloat() < 0.05;
        if (!self.leader[index]) return;
        self.reinforcement_chance[index] += 0.5 + spawn_random.nextDouble() * 0.25;
        self.max_health[index] *= @floatCast(2 + spawn_random.nextDouble() * 3);
        self.health[index] = self.max_health[index];
        self.can_break_doors[index] = true;
    }

    pub fn remove(self: *Pool, handle: Handle) bool {
        self.assertInvariants();
        if (!self.isAlive(handle)) return false;

        const before_active = self.active_count;
        const before_free = self.free_count;
        const index = handle.index;
        const active_position: usize = self.active_positions[index];
        std.debug.assert(self.active_indices[active_position] == index);

        if (active_position + 1 < self.active_count) {
            std.mem.copyForwards(
                u16,
                self.active_indices[active_position .. self.active_count - 1],
                self.active_indices[active_position + 1 .. self.active_count],
            );
            for (active_position..self.active_count - 1) |position| {
                self.active_positions[self.active_indices[position]] = @intCast(position);
            }
        }
        self.active_count -= 1;
        self.active[index] = false;
        self.targets[index] = .none;
        self.vehicles[index] = no_vehicle;
        self.restored_vehicle_uuids[index] = 0;
        self.jockey_candidate[index] = false;
        self.generations[index] +%= 1;
        if (self.generations[index] == 0) self.generations[index] = 1;
        self.free_indices[self.free_count] = index;
        self.free_count += 1;

        std.debug.assert(self.active_count + 1 == before_active);
        std.debug.assert(self.free_count == before_free + 1);
        std.debug.assert(!self.isAlive(handle));
        self.assertInvariants();
        return true;
    }

    pub fn isAlive(self: *const Pool, handle: Handle) bool {
        return handle.index < self.active.len and self.active[handle.index] and self.generations[handle.index] == handle.generation;
    }

    pub fn vehicleFor(self: *const Pool, rider: Handle) ?Handle {
        if (!self.isAlive(rider)) return null;
        const vehicle = self.vehicles[rider.index];
        return if (vehicle.index == no_vehicle.index) null else vehicle;
    }

    pub fn setVehicle(self: *Pool, rider: Handle, vehicle: Handle) bool {
        if (!self.isAlive(rider) or !self.isAlive(vehicle)) return false;
        if (rider.index == vehicle.index) return false;
        for (self.active_indices[0..self.active_count]) |candidate| {
            if (candidate == rider.index) continue;
            if (self.vehicles[candidate].index != vehicle.index) continue;
            if (self.vehicles[candidate].generation != vehicle.generation) continue;
            return false;
        }
        self.vehicles[rider.index] = vehicle;
        return true;
    }

    pub fn clearVehicle(self: *Pool, rider: Handle) void {
        if (!self.isAlive(rider)) return;
        self.vehicles[rider.index] = no_vehicle;
        self.restored_vehicle_uuids[rider.index] = 0;
    }

    pub fn indexForEntityId(self: *const Pool, entity_id: i32) ?u16 {
        const offset = entity_id - self.first_entity_id;
        if (offset < 0 or offset >= self.active.len) return null;
        const index: u16 = @intCast(offset);
        return if (self.active[index] and self.entity_ids[index] == entity_id) index else null;
    }

    pub fn entity(self: *const Pool, handle: Handle) ?Entity {
        if (!self.isAlive(handle)) return null;
        const index = handle.index;
        return .{
            .handle = handle,
            .world = self.worlds[index],
            .entity_type = self.entity_types[index],
            .entity_id = self.entity_ids[index],
            .uuid = self.uuids[index],
            .position = .{ .x = self.position_x[index], .y = self.position_y[index], .z = self.position_z[index] },
            .velocity = .{ .x = self.velocity_x[index], .y = self.velocity_y[index], .z = self.velocity_z[index] },
            .yaw = self.yaw[index],
            .pitch = self.pitch[index],
            .body_yaw = self.body_yaw[index],
            .head_yaw = self.head_yaw[index],
            .health = self.health[index],
            .fire_ticks = self.fire_ticks[index],
            .despawn_counter = self.despawn_counter[index],
            .target = self.targets[index],
            .vehicle = self.vehicleFor(handle),
            .baby = self.baby[index],
            .breeding_age = self.breeding_age[index],
            .love_ticks = self.love_ticks[index],
            .persistent = self.persistent[index],
            .on_ground = self.on_ground[index],
            .age = self.age[index],
            .target_goal_running = self.target_goal_running[index],
            .melee_goal_running = self.melee_goal_running[index],
            .attacking = self.attacking[index],
        };
    }

    pub fn transfer(self: *Pool, handle: Handle, world: world_identity.Handle, position: Position) bool {
        if (!self.isAlive(handle) or !world_identity.valid(world)) return false;
        const index = handle.index;
        self.worlds[index] = world;
        self.position_x[index] = position.x;
        self.position_y[index] = position.y;
        self.position_z[index] = position.z;
        self.targets[index] = .none;
        self.vehicles[index] = no_vehicle;
        self.restored_vehicle_uuids[index] = 0;
        self.target_goal_running[index] = false;
        self.melee_goal_running[index] = false;
        self.melee_update_countdown[index] = 0;
        return true;
    }

    pub fn assertInvariants(self: *const Pool) void {
        if (self.initialized and self.active_count + self.free_count != self.active.len)
            diagnostics.panic("living pool invariant failed (active count, free count, capacity)", &.{ diagnostics.integer(self.active_count), diagnostics.integer(self.free_count), diagnostics.integer(self.active.len) });
        if (self.active_count > self.active.len)
            diagnostics.panic("living pool invariant failed (active count, capacity)", &.{ diagnostics.integer(self.active_count), diagnostics.integer(self.active.len) });
        if (self.free_count > self.active.len)
            diagnostics.panic("living pool invariant failed (free count, capacity)", &.{ diagnostics.integer(self.free_count), diagnostics.integer(self.active.len) });
        if (!self.initialized) return;
        for (self.active_indices[0..self.active_count], 0..) |index, position| {
            if (index >= self.active.len)
                diagnostics.panic("living pool invariant failed (active index, list position, capacity)", &.{ diagnostics.integer(index), diagnostics.integer(position), diagnostics.integer(self.active.len) });
            if (!self.active[index])
                diagnostics.panic("living pool invariant failed: active-list entry is marked inactive (index, list position)", &.{ diagnostics.integer(index), diagnostics.integer(position) });
            if (self.active_positions[index] != position)
                diagnostics.panic("living pool invariant failed (index, recorded active position, expected position)", &.{ diagnostics.integer(index), diagnostics.integer(self.active_positions[index]), diagnostics.integer(position) });
            if (self.generations[index] == 0)
                diagnostics.panic("living pool invariant failed: active index has generation zero (index)", &.{diagnostics.integer(index)});
            if (!std.math.isFinite(self.position_x[index]) or !std.math.isFinite(self.position_y[index]) or !std.math.isFinite(self.position_z[index]))
                diagnostics.panic("living pool invariant failed: non-finite position (index, type, x, y, z, velocity x, velocity y, velocity z)", &.{
                    diagnostics.integer(index),
                    diagnostics.text(@tagName(self.entity_types[index])),
                    diagnostics.float(self.position_x[index]),
                    diagnostics.float(self.position_y[index]),
                    diagnostics.float(self.position_z[index]),
                    diagnostics.float(self.velocity_x[index]),
                    diagnostics.float(self.velocity_y[index]),
                    diagnostics.float(self.velocity_z[index]),
                });
        }
    }

    fn applyTypeDefaults(self: *Pool, index: usize, entity_type: EntityType, is_baby: bool) void {
        switch (entity_type) {
            .zombie => {
                self.health[index] = 20;
                self.max_health[index] = 20;
                self.follow_range[index] = 35;
                const baby_multiplier: f64 = if (is_baby) 1.5 else 1.0;
                self.movement_speed[index] = @as(f64, 0.23000000417232513) * baby_multiplier;
                self.attack_damage[index] = 3;
                self.armor[index] = 2;
            },
            .zombified_piglin => {
                self.health[index] = 20;
                self.max_health[index] = 20;
                self.follow_range[index] = 35;
                self.movement_speed[index] = 0.23000000417232513;
                self.attack_damage[index] = 5;
                self.armor[index] = 2;
            },
            .turtle => {
                self.health[index] = 30;
                self.max_health[index] = 30;
                self.follow_range[index] = 16;
                self.movement_speed[index] = 0.25;
                self.attack_damage[index] = 0;
                self.armor[index] = 0;
            },
            .cow => {
                self.health[index] = 10;
                self.max_health[index] = 10;
                self.follow_range[index] = 10;
                self.movement_speed[index] = 0.2;
                self.attack_damage[index] = 0;
                self.armor[index] = 0;
            },
            .pig => {
                self.health[index] = 10;
                self.max_health[index] = 10;
                self.follow_range[index] = 10;
                self.movement_speed[index] = 0.25;
                self.attack_damage[index] = 0;
                self.armor[index] = 0;
            },
            .chicken => {
                self.health[index] = 4;
                self.max_health[index] = 4;
                self.follow_range[index] = 10;
                self.movement_speed[index] = 0.25;
                self.attack_damage[index] = 0;
                self.armor[index] = 0;
            },
        }
    }

    fn entityId(self: *const Pool, index: usize) i32 {
        return self.first_entity_id + @as(i32, @intCast(index));
    }
};

pub fn width(entity_type: EntityType, baby: bool) f32 {
    const adult: f32 = switch (entity_type) {
        .zombie, .zombified_piglin => 0.6,
        .turtle => 1.2,
        .cow, .pig => 0.9,
        .chicken => 0.4,
    };
    return if (baby) adult * 0.5 else adult;
}

pub fn height(entity_type: EntityType, baby: bool) f32 {
    const adult: f32 = switch (entity_type) {
        .zombie, .zombified_piglin => 1.95,
        .turtle => 0.4,
        .cow => 1.4,
        .pig => 0.9,
        .chicken => 0.7,
    };
    return if (baby) adult * 0.5 else adult;
}

pub fn canDespawn(entity_type: EntityType) bool {
    return switch (entity_type) {
        .zombie, .zombified_piglin => true,
        .turtle, .cow, .pig, .chicken => false,
    };
}

test "generational handles reject stale living entity references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    const first = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 1, .y = 64, .z = 2 }, .uuid = 1, .random_seed = 1 });
    try std.testing.expect(pool.remove(first));
    const second = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 3, .y = 64, .z = 4 }, .uuid = 2, .random_seed = 2 });
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expect(!pool.isAlive(first));
    try std.testing.expect(pool.isAlive(second));
}

test "passive animals do not use hostile mob despawning" {
    try std.testing.expect(canDespawn(.zombie));
    try std.testing.expect(canDespawn(.zombified_piglin));
    try std.testing.expect(!canDespawn(.turtle));
    try std.testing.expect(!canDespawn(.cow));
    try std.testing.expect(!canDespawn(.pig));
}

test "a bounded vehicle relation accepts one live passenger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    const chicken = try pool.spawn(.{ .world = test_world, .entity_type = .chicken, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 1, .random_seed = 1 });
    const first = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 2, .random_seed = 2, .baby = true });
    const second = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 3, .random_seed = 3, .baby = true });
    try std.testing.expect(pool.setVehicle(first, chicken));
    try std.testing.expect(!pool.setVehicle(second, chicken));
    try std.testing.expectEqual(chicken, pool.vehicleFor(first).?);
}

test "world transfer preserves intrinsic state and clears world-relative goals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    const entity = try pool.spawn(.{
        .world = test_world,
        .entity_type = .zombie,
        .position = .{ .x = 1, .y = 64, .z = 2 },
        .uuid = 1,
        .random_seed = 9,
    });
    pool.health[entity.index] = 7;
    pool.age[entity.index] = 200;
    pool.targets[entity.index] = .{ .player = 3 };
    pool.target_goal_running[entity.index] = true;
    pool.melee_goal_running[entity.index] = true;
    const destination = world_identity.Handle{ .index = 2, .generation = 4 };
    try std.testing.expect(pool.transfer(entity, destination, .{ .x = 8, .y = 80, .z = -3 }));
    try std.testing.expect(pool.worlds[entity.index].eql(destination));
    try std.testing.expectEqual(@as(f32, 7), pool.health[entity.index]);
    try std.testing.expectEqual(@as(u32, 200), pool.age[entity.index]);
    try std.testing.expectEqual(Target.none, pool.targets[entity.index]);
    try std.testing.expect(!pool.target_goal_running[entity.index]);
    try std.testing.expect(!pool.melee_goal_running[entity.index]);
}

test "removal preserves stable living entity tick order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    const a = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 1, .random_seed = 1 });
    const b = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 1, .y = 64, .z = 0 }, .uuid = 2, .random_seed = 2 });
    const c = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 2, .y = 64, .z = 0 }, .uuid = 3, .random_seed = 3 });
    try std.testing.expect(pool.remove(b));
    try std.testing.expectEqualSlices(u16, &.{ a.index, c.index }, pool.active_indices[0..pool.active_count]);
}

test "cow and pig defaults are vanilla-sized passive animals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    const cow = try pool.spawn(.{ .world = test_world, .entity_type = .cow, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 1, .random_seed = 1 });
    const pig = try pool.spawn(.{ .world = test_world, .entity_type = .pig, .position = .{ .x = 1, .y = 64, .z = 0 }, .uuid = 2, .random_seed = 2 });
    try std.testing.expectEqual(@as(f32, 10), pool.health[cow.index]);
    try std.testing.expectEqual(@as(f64, 0.2), pool.movement_speed[cow.index]);
    try std.testing.expectEqual(@as(f32, 0.9), width(.cow, false));
    try std.testing.expectEqual(@as(f32, 1.4), height(.cow, false));
    try std.testing.expectEqual(@as(f32, 10), pool.health[pig.index]);
    try std.testing.expectEqual(@as(f64, 0.25), pool.movement_speed[pig.index]);
    try std.testing.expect(!pool.leader[cow.index]);
    try std.testing.expect(!pool.can_break_doors[pig.index]);
}

test "zombie defaults match the 1.21.8 attribute contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    const adult = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 1, .random_seed = 1 });
    const baby = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = 2, .baby = true, .random_seed = 2 });
    try std.testing.expectEqual(@as(f32, 20), pool.health[adult.index]);
    try std.testing.expectEqual(@as(f64, 35), pool.follow_range[adult.index]);
    try std.testing.expectEqual(@as(f64, 3), pool.attack_damage[adult.index]);
    try std.testing.expectEqual(@as(f64, 2), pool.armor[adult.index]);
    try std.testing.expectEqual(pool.movement_speed[adult.index] * 1.5, pool.movement_speed[baby.index]);
}

test "zombie leader initialization applies the reinforcement and health contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool: Pool = undefined;
    try pool.allocate(arena.allocator(), .{ .first_entity_id = 1 });
    var found_leader = false;
    for (0..256) |seed| {
        const zombie = try pool.spawn(.{ .world = test_world, .entity_type = .zombie, .position = .{ .x = 0, .y = 64, .z = 0 }, .uuid = seed + 1, .random_seed = seed });
        if (pool.leader[zombie.index]) {
            try std.testing.expect(pool.reinforcement_chance[zombie.index] >= 0.5);
            try std.testing.expect(pool.max_health[zombie.index] >= 40 and pool.max_health[zombie.index] <= 100);
            try std.testing.expectEqual(pool.max_health[zombie.index], pool.health[zombie.index]);
            try std.testing.expect(pool.can_break_doors[zombie.index]);
            found_leader = true;
        }
        try std.testing.expect(pool.remove(zombie));
        if (found_leader) break;
    }
    try std.testing.expect(found_leader);
}
