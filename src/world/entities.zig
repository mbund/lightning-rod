const player_store = @import("players.zig");
const block_store = @import("blocks.zig");
const std = @import("std");
const registry = @import("registry_data");
const config = @import("../config.zig").value;
const living_entities = @import("../living_entities.zig");
const navigation = @import("../navigation.zig");
const diagnostics = @import("../diagnostics.zig");
const geometry = @import("geometry.zig");
const world_random = @import("random.zig");
const world_identity = @import("identity.zig");

const cache_line_size = 64;

pub fn livingEntityCanonicalTypeId(entity_type: living_entities.EntityType) i32 {
    return switch (entity_type) {
        .zombie => registry.entity_zombie_type_id,
        .zombified_piglin => registry.entity_zombified_piglin_type_id,
        .turtle => registry.entity_turtle_type_id,
        .cow => registry.entity_cow_type_id,
        .pig => registry.entity_pig_type_id,
    };
}

pub const item_entity_sentinel: u16 = std.math.maxInt(u16);

const item_spatial_cell_size: i32 = 2;
const item_gravity_per_tick: f64 = 0.04;
const item_air_friction: f64 = 0.98;
const item_ground_friction: f64 = 0.6;
pub const block_drop_pickup_delay_ticks: u16 = 10;
pub const player_drop_pickup_delay_ticks: u16 = 40;
/// Vanilla removes an ordinary item entity after five minutes at 20 TPS.
/// Keeping this bounded is also essential for recovering slots in the fixed
/// item-entity pool on long-running servers.
pub const item_despawn_age_ticks: u32 = 5 * 60 * 20;

pub const ItemEntity = extern struct {
    world: world_identity.Handle = world_identity.invalid,
    position: geometry.Vec3 = .{},
    velocity: geometry.Vec3 = .{},
    entity_id: i32 = 0,
    age_ticks: u32 = 0,
    pickup_delay_ticks: u16 = 10,
    active: bool = false,
    on_ground: bool = false,
    stack: player_store.HotbarStack = .{},
    uuid: u128 = 0,
};

pub const LivingEntities = struct {
    pub const id = "lightning_rod:living_entities";

    entities: living_entities.Pool = .{},
    paths: navigation.Paths = .{},
    search: navigation.Search = .{},

    pub fn create(allocator: std.mem.Allocator) !*LivingEntities {
        const self = try allocator.create(LivingEntities);
        self.* = .{};
        try self.entities.allocate(allocator);
        try self.paths.allocate(allocator);
        try self.search.allocate(allocator);
        return self;
    }

    pub fn spawn(
        self: *LivingEntities,
        random: *world_random.Random,
        block_world: *block_store.Blocks,
        world: world_identity.Handle,
        entity_type: living_entities.EntityType,
        position: geometry.Vec3,
        baby: bool,
        persistent: bool,
    ) !living_entities.Handle {
        if (self.entities.free_count == 0) return error.LivingEntityCapacity;
        const block_position = geometry.BlockPos{
            .x = geometry.blockCoord(position.x),
            .y = @intCast(@max(@as(i32, config.world_min_y), @min(geometry.blockCoord(position.y), @as(i32, block_store.world_top_y)))),
            .z = geometry.blockCoord(position.z),
        };
        if (block_world.residentChunk(world, geometry.chunkForBlock(block_position)) == null)
            return error.SpawnChunkNotResident;
        const handle = try self.entities.spawn(.{
            .world = world,
            .entity_type = entity_type,
            .position = .{ .x = position.x, .y = position.y, .z = position.z },
            .uuid = random.random.uuid_for_living(@intCast(self.entities.active_count)),
            .random_seed = random.random.next(),
            .baby = baby,
            .persistent = persistent,
        });
        self.paths.clear(handle.index);
        return handle;
    }

    pub fn transfer(
        self: *LivingEntities,
        handle: living_entities.Handle,
        world: world_identity.Handle,
        position: geometry.Vec3,
    ) bool {
        if (!self.entities.transfer(handle, world, .{
            .x = position.x,
            .y = position.y,
            .z = position.z,
        })) return false;
        self.paths.clear(handle.index);
        return true;
    }
};

pub const ItemEntities = struct {
    pub const id = "lightning_rod:item_entities";

    worlds: []align(cache_line_size) world_identity.Handle = &.{},
    position_x: []align(cache_line_size) f64 = &.{},
    position_y: []align(cache_line_size) f64 = &.{},
    position_z: []align(cache_line_size) f64 = &.{},
    velocity_x: []align(cache_line_size) f64 = &.{},
    velocity_y: []align(cache_line_size) f64 = &.{},
    velocity_z: []align(cache_line_size) f64 = &.{},
    age_ticks: []align(cache_line_size) u32 = &.{},
    pickup_delay_ticks: []align(cache_line_size) u16 = &.{},
    entity_ids: []align(cache_line_size) i32 = &.{},
    active: []align(cache_line_size) bool = &.{},
    on_ground: []align(cache_line_size) bool = &.{},
    stacks: []align(cache_line_size) player_store.HotbarStack = &.{},
    uuids: []align(cache_line_size) u128 = &.{},
    active_indices: []align(cache_line_size) u16 = &.{},
    active_positions: []align(cache_line_size) u16 = &.{},
    next_in_bucket: []align(cache_line_size) u16 = &.{},
    bucket_indices: []align(cache_line_size) u16 = &.{},
    cell_x: []align(cache_line_size) i32 = &.{},
    cell_z: []align(cache_line_size) i32 = &.{},
    bucket_heads: []align(cache_line_size) u16 = &.{},
    active_count: usize = 0,
    free_indices: []align(cache_line_size) u16 = &.{},
    free_count: usize = 0,
    free_list_initialized: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*ItemEntities {
        const self = try allocator.create(ItemEntities);
        self.* = .{};
        self.position_x = try allocator.alignedAlloc(f64, .@"64", config.max_item_entities);
        self.worlds = try allocator.alignedAlloc(world_identity.Handle, .@"64", config.max_item_entities);
        self.position_y = try allocator.alignedAlloc(f64, .@"64", config.max_item_entities);
        self.position_z = try allocator.alignedAlloc(f64, .@"64", config.max_item_entities);
        self.velocity_x = try allocator.alignedAlloc(f64, .@"64", config.max_item_entities);
        self.velocity_y = try allocator.alignedAlloc(f64, .@"64", config.max_item_entities);
        self.velocity_z = try allocator.alignedAlloc(f64, .@"64", config.max_item_entities);
        self.age_ticks = try allocator.alignedAlloc(u32, .@"64", config.max_item_entities);
        self.pickup_delay_ticks = try allocator.alignedAlloc(u16, .@"64", config.max_item_entities);
        self.entity_ids = try allocator.alignedAlloc(i32, .@"64", config.max_item_entities);
        self.active = try allocator.alignedAlloc(bool, .@"64", config.max_item_entities);
        self.on_ground = try allocator.alignedAlloc(bool, .@"64", config.max_item_entities);
        self.stacks = try allocator.alignedAlloc(player_store.HotbarStack, .@"64", config.max_item_entities);
        self.uuids = try allocator.alignedAlloc(u128, .@"64", config.max_item_entities);
        self.active_indices = try allocator.alignedAlloc(u16, .@"64", config.max_item_entities);
        self.active_positions = try allocator.alignedAlloc(u16, .@"64", config.max_item_entities);
        self.next_in_bucket = try allocator.alignedAlloc(u16, .@"64", config.max_item_entities);
        self.bucket_indices = try allocator.alignedAlloc(u16, .@"64", config.max_item_entities);
        self.cell_x = try allocator.alignedAlloc(i32, .@"64", config.max_item_entities);
        self.cell_z = try allocator.alignedAlloc(i32, .@"64", config.max_item_entities);
        self.bucket_heads = try allocator.alignedAlloc(u16, .@"64", config.item_spatial_bucket_count);
        self.free_indices = try allocator.alignedAlloc(u16, .@"64", config.max_item_entities);
        @memset(self.position_x, 0);
        @memset(self.worlds, world_identity.invalid);
        @memset(self.position_y, 0);
        @memset(self.position_z, 0);
        @memset(self.velocity_x, 0);
        @memset(self.velocity_y, 0);
        @memset(self.velocity_z, 0);
        @memset(self.age_ticks, 0);
        @memset(self.pickup_delay_ticks, 0);
        @memset(self.entity_ids, 0);
        @memset(self.active, false);
        @memset(self.on_ground, false);
        @memset(self.stacks, .{});
        @memset(self.uuids, 0);
        @memset(self.next_in_bucket, item_entity_sentinel);
        @memset(self.bucket_indices, item_entity_sentinel);
        @memset(self.bucket_heads, item_entity_sentinel);
        return self;
    }

    pub fn resetInPlace(self: *ItemEntities) void {
        for (self.active_indices[0..self.active_count]) |index| {
            self.active[index] = false;
            self.next_in_bucket[index] = item_entity_sentinel;
            self.bucket_indices[index] = item_entity_sentinel;
        }
        self.active_count = 0;
        self.free_count = config.max_item_entities;
        for (0..config.max_item_entities) |index|
            self.free_indices[index] = @intCast(config.max_item_entities - 1 - index);
        self.free_list_initialized = true;
        @memset(self.bucket_heads, item_entity_sentinel);
    }

    pub fn spawn(
        self: *ItemEntities,
        random: *world_random.Random,
        block_world: *block_store.Blocks,
        world: world_identity.Handle,
        spawn_position: geometry.Vec3,
        velocity: geometry.Vec3,
        stack: player_store.HotbarStack,
        pickup_delay_ticks: u16,
    ) !usize {
        if (!world_identity.valid(world)) return error.InvalidWorld;
        if (stack.isEmpty()) return error.EmptyItemEntity;
        if (block_world.residentChunk(world, geometry.chunkForBlock(.{
            .x = geometry.blockCoord(spawn_position.x),
            .y = @intCast(std.math.clamp(
                geometry.blockCoord(spawn_position.y),
                @as(i32, config.world_min_y),
                @as(i32, block_store.world_top_y),
            )),
            .z = geometry.blockCoord(spawn_position.z),
        })) == null) return error.SpawnChunkNotResident;
        self.ensureFreeList();
        if (self.free_count == 0) return error.ItemEntityCapacity;
        const before_count = self.active_count;
        self.free_count -= 1;
        const index = self.free_indices[self.free_count];
        self.set(index, .{
            .world = world,
            .active = true,
            .entity_id = itemEntityIdForIndex(index),
            .uuid = random.random.uuid_for_item(index),
            .position = sanitizePosition(spawn_position),
            .velocity = sanitizeVelocity(velocity),
            .stack = stack,
            .pickup_delay_ticks = pickup_delay_ticks,
        });
        self.active_indices[before_count] = index;
        self.active_positions[index] = @intCast(before_count);
        self.active_count += 1;
        self.insertBucket(index);
        return index;
    }

    pub fn set(self: *ItemEntities, index: usize, entity: ItemEntity) void {
        std.debug.assert(index < config.max_item_entities);
        self.worlds[index] = entity.world;
        self.position_x[index] = entity.position.x;
        self.position_y[index] = entity.position.y;
        self.position_z[index] = entity.position.z;
        self.velocity_x[index] = entity.velocity.x;
        self.velocity_y[index] = entity.velocity.y;
        self.velocity_z[index] = entity.velocity.z;
        self.entity_ids[index] = entity.entity_id;
        self.age_ticks[index] = entity.age_ticks;
        self.pickup_delay_ticks[index] = entity.pickup_delay_ticks;
        self.active[index] = entity.active;
        self.on_ground[index] = entity.on_ground;
        self.stacks[index] = entity.stack;
        self.uuids[index] = entity.uuid;
    }

    pub inline fn position(self: *const ItemEntities, index: usize) geometry.Vec3 {
        return .{
            .x = self.position_x[index],
            .y = self.position_y[index],
            .z = self.position_z[index],
        };
    }

    pub fn value(self: *const ItemEntities, index: usize) ItemEntity {
        std.debug.assert(index < config.max_item_entities);
        return .{
            .world = self.worlds[index],
            .position = self.position(index),
            .velocity = .{
                .x = self.velocity_x[index],
                .y = self.velocity_y[index],
                .z = self.velocity_z[index],
            },
            .entity_id = self.entity_ids[index],
            .age_ticks = self.age_ticks[index],
            .pickup_delay_ticks = self.pickup_delay_ticks[index],
            .active = self.active[index],
            .on_ground = self.on_ground[index],
            .stack = self.stacks[index],
            .uuid = self.uuids[index],
        };
    }

    pub fn restoreEntity(
        self: *ItemEntities,
        random: *world_random.Random,
        block_world: *block_store.Blocks,
        saved: ItemEntity,
    ) !usize {
        const index = try self.spawn(
            random,
            block_world,
            saved.world,
            saved.position,
            saved.velocity,
            saved.stack,
            saved.pickup_delay_ticks,
        );
        const entity_id = self.entity_ids[index];
        self.removeBucket(index);
        var restored = saved;
        restored.active = true;
        restored.entity_id = entity_id;
        self.set(index, restored);
        self.insertBucket(@intCast(index));
        return index;
    }

    pub fn remove(self: *ItemEntities, index: usize) void {
        std.debug.assert(index < config.max_item_entities);
        if (!self.active[index]) return;
        self.removeBucket(index);
        const active_position: usize = self.active_positions[index];
        self.active_count -= 1;
        const moved_index = self.active_indices[self.active_count];
        self.active_indices[active_position] = moved_index;
        self.active_positions[moved_index] = @intCast(active_position);
        self.set(index, .{});
        self.free_indices[self.free_count] = @intCast(index);
        self.free_count += 1;
    }

    pub fn updateBucket(self: *ItemEntities, index: usize) void {
        std.debug.assert(index < config.max_item_entities and self.active[index]);
        const cell = itemSpatialCell(self.position(index));
        const bucket = itemSpatialBucketForCell(self.worlds[index], cell.x, cell.z);
        if (self.bucket_indices[index] == bucket and
            self.cell_x[index] == cell.x and
            self.cell_z[index] == cell.z) return;
        self.removeBucket(index);
        self.cell_x[index] = cell.x;
        self.cell_z[index] = cell.z;
        self.bucket_indices[index] = bucket;
        self.next_in_bucket[index] = self.bucket_heads[bucket];
        self.bucket_heads[bucket] = @intCast(index);
    }

    pub fn transfer(
        self: *ItemEntities,
        index: u16,
        world: world_identity.Handle,
        destination: geometry.Vec3,
        velocity: ?geometry.Vec3,
    ) bool {
        if (index >= self.active.len or !self.active[index] or !world_identity.valid(world))
            return false;
        self.removeBucket(index);
        self.worlds[index] = world;
        self.position_x[index] = destination.x;
        self.position_y[index] = destination.y;
        self.position_z[index] = destination.z;
        if (velocity) |new_velocity| {
            self.velocity_x[index] = new_velocity.x;
            self.velocity_y[index] = new_velocity.y;
            self.velocity_z[index] = new_velocity.z;
        }
        self.on_ground[index] = false;
        self.insertBucket(index);
        return true;
    }

    fn ensureFreeList(self: *ItemEntities) void {
        if (self.free_list_initialized) return;
        for (0..config.max_item_entities) |index|
            self.free_indices[index] = @intCast(config.max_item_entities - 1 - index);
        self.free_count = config.max_item_entities;
        self.free_list_initialized = true;
    }

    fn insertBucket(self: *ItemEntities, index: u16) void {
        const item_position = geometry.Vec3{
            .x = self.position_x[index],
            .y = self.position_y[index],
            .z = self.position_z[index],
        };
        const cell = itemSpatialCell(item_position);
        const bucket = itemSpatialBucketForCell(self.worlds[index], cell.x, cell.z);
        self.cell_x[index] = cell.x;
        self.cell_z[index] = cell.z;
        self.bucket_indices[index] = bucket;
        self.next_in_bucket[index] = self.bucket_heads[bucket];
        self.bucket_heads[bucket] = index;
    }

    fn removeBucket(self: *ItemEntities, index: usize) void {
        const bucket = self.bucket_indices[index];
        if (bucket == item_entity_sentinel) return;
        var current = self.bucket_heads[bucket];
        var previous: u16 = item_entity_sentinel;
        for (0..config.max_item_entities) |_| {
            if (current == item_entity_sentinel) break;
            if (current == index) {
                if (previous == item_entity_sentinel)
                    self.bucket_heads[bucket] = self.next_in_bucket[current]
                else
                    self.next_in_bucket[previous] = self.next_in_bucket[current];
                self.next_in_bucket[index] = item_entity_sentinel;
                self.bucket_indices[index] = item_entity_sentinel;
                return;
            }
            previous = current;
            current = self.next_in_bucket[current];
        } else diagnostics.panic("item spatial bucket contains a cycle", &.{});
        diagnostics.panic("item spatial bucket is missing its indexed entity", &.{});
    }
};

pub fn itemSpatialCell(position: geometry.Vec3) struct { x: i32, z: i32 } {
    return .{ .x = @divFloor(geometry.blockCoord(position.x), item_spatial_cell_size), .z = @divFloor(geometry.blockCoord(position.z), item_spatial_cell_size) };
}

pub fn itemSpatialBucket(world: world_identity.Handle, position: geometry.Vec3) u16 {
    const cell = itemSpatialCell(position);
    return itemSpatialBucketForCell(world, cell.x, cell.z);
}

pub fn itemSpatialBucketForCell(world: world_identity.Handle, cell_x: i32, cell_z: i32) u16 {
    var value: u64 = 0x243f_6a88_85a3_08d3;
    value ^= @as(u32, @bitCast(world));
    value *%= 0x94d0_49bb_1331_11eb;
    value ^= @as(u32, @bitCast(cell_x));
    value *%= 0x9e37_79b9_7f4a_7c15;
    value ^= @as(u32, @bitCast(cell_z));
    value *%= 0xbf58_476d_1ce4_e5b9;
    return @intCast(value & (config.item_spatial_bucket_count - 1));
}

pub fn blockDropPosition(pos: geometry.BlockPos) geometry.Vec3 {
    return .{
        .x = @as(f64, @floatFromInt(pos.x)) + 0.5,
        .y = @as(f64, @floatFromInt(pos.y)) + 0.5,
        .z = @as(f64, @floatFromInt(pos.z)) + 0.5,
    };
}

fn itemEntityIdForIndex(index: usize) i32 {
    return @intCast(config.connectionCapacity() + index + 1);
}

fn sanitizePosition(value: geometry.Vec3) geometry.Vec3 {
    return .{ .x = finiteOrZero(value.x), .y = finiteOrZero(value.y), .z = finiteOrZero(value.z) };
}

fn sanitizeVelocity(value: geometry.Vec3) geometry.Vec3 {
    return .{ .x = finiteOrZero(value.x), .y = finiteOrZero(value.y), .z = finiteOrZero(value.z) };
}

fn finiteOrZero(value: f64) f64 {
    return if (std.math.isFinite(value)) value else 0;
}

pub fn itemGroundY(blocks: *block_store.Blocks, world: world_identity.Handle, position: geometry.Vec3) ?f64 {
    const x = geometry.blockCoord(position.x);
    const z = geometry.blockCoord(position.z);
    if (blocks.residentChunk(world, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }) == null)
        return null;
    const max_y: i16 = @intCast(@min(geometry.blockCoord(position.y - 0.01), block_store.world_top_y));
    const solid_y = highestSolidBlockAtOrBelow(blocks, world, x, z, max_y) orelse return null;
    return @floatFromInt(@as(i32, solid_y) + 1);
}

fn highestSolidBlockAtOrBelow(blocks: *const block_store.Blocks, world: world_identity.Handle, x: i32, z: i32, max_y: i16) ?i16 {
    if (max_y < config.world_min_y) return null;
    const chunk = geometry.ChunkPos{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) };
    var highest: ?i16 = null;

    var base_y = @min(max_y, blocks.highestGeneratedY(world, x, z));
    while (base_y >= config.world_min_y) : (base_y -= 1) {
        if (blocks.blockAt(world, .{ .x = x, .y = base_y, .z = z }) != registry.block_air_default_state) {
            highest = base_y;
            break;
        }
    }

    const max_section = block_store.sectionIndexForY(max_y) orelse return highest;
    for (0..max_section + 1) |section| {
        _ = blocks.findModifiedSection(world, chunk, section) orelse continue;
        var local_y: usize = 16;
        while (local_y != 0) {
            local_y -= 1;
            const y = block_store.sectionWorldY(section, local_y);
            if (y > max_y or (highest != null and y <= highest.?)) continue;
            if (blocks.blockAt(world, .{ .x = x, .y = y, .z = z }) != registry.block_air_default_state) {
                highest = y;
                break;
            }
        }
    }
    return highest;
}
