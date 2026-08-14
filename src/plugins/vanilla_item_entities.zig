const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const world_clock = lightning_rod.clock;
const std = @import("std");
const plugin_profiler = lightning_rod.plugin_profiler;
const config = lightning_rod.config.value;
const registry = lightning_rod.registry_data;
const Packets = lightning_rod.Packets;

pub const ItemEntities = struct {
    pub const id = "minecraft:item_entity_tick";
    pub const Trace = ItemEntityTrace;

    merge_due: []bool = &.{},
    pending_metadata: []u16 = &.{},
    pending_metadata_count: usize = 0,
    clock: *world_clock.Clock,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, blocks: *block_store.Blocks, players: *player_store.Players, items: *entity_store.ItemEntities, outputs: *Packets) !*ItemEntities {
        const self = try allocator.create(ItemEntities);
        self.* = .{ .clock = clock, .blocks = blocks, .players = players, .items = items, .outputs = outputs };
        self.merge_due = try allocator.alloc(bool, config.max_item_entities);
        self.pending_metadata = try allocator.alloc(u16, config.max_item_entities);
        @memset(self.merge_due, false);
        return self;
    }

    pub fn tick(self: *ItemEntities, _: std.mem.Allocator) void {
        const clock = self.clock;
        const blocks = self.blocks;
        const players = self.players;
        const items = self.items;
        const outputs = self.outputs;
        outputs.reconcile_item_entities();
        self.run(clock, blocks, players, items, outputs);
        outputs.reconcile_item_entities();
    }

    const item_gravity_per_tick: f64 = 0.04;
    const item_air_friction: f64 = 0.98;
    const item_ground_friction: f64 = 0.588;
    const infinite_pickup_delay: u16 = 32_767;

    const ItemEntityTrace = enum {
        player_pickups,
        stack_merges,
        despawns,
    };

    fn distanceSquared(a: geometry.Vec3, b: geometry.Vec3) f64 {
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        const dz = a.z - b.z;
        return dx * dx + dy * dy + dz * dz;
    }

    fn playerCanPickupItem(player: *const player_store.CorePlayer, item_position: geometry.Vec3) bool {
        return distanceSquared(player.position, item_position) <= 2.25;
    }

    fn run(self: *ItemEntities, clock: *world_clock.Clock, blocks: *block_store.Blocks, players: *player_store.Players, items: *entity_store.ItemEntities, outputs: *Packets) void {
        for (self.pending_metadata[0..self.pending_metadata_count]) |index|
            if (items.active[index]) outputs.item_metadata_changed(index);
        self.pending_metadata_count = 0;

        var batch_start: usize = 0;
        while (batch_start < items.active_count) : (batch_start += 4) {
            self.tickItemPhysicsBatch(clock, blocks, items, batch_start, @min(4, items.active_count - batch_start), outputs);
        }
        var active_position: usize = 0;
        while (active_position < items.active_count) {
            const index = items.active_indices[active_position];
            if (items.age_ticks[index] >= entity_store.item_despawn_age_ticks) {
                const entity_id = items.entity_ids[index];
                items.remove(index);
                outputs.entity_destroyed(entity_id);
                plugin_profiler.countTrace(ItemEntityTrace.despawns, 1);
                continue;
            }
            if (self.merge_due[index] and self.tryStackItemEntity(items, index, outputs)) continue;
            if (items.pickup_delay_ticks[index] == 0 and tryPickupItemEntity(players, items, index, outputs)) continue;
            active_position += 1;
        }
    }

    fn tickItemPhysicsBatch(
        self: *ItemEntities,
        clock: *world_clock.Clock,
        blocks: *block_store.Blocks,
        items: *entity_store.ItemEntities,
        active_start: usize,
        lane_count: usize,
        outputs: *Packets,
    ) void {
        var batch = loadPhysicsBatch(items, active_start, lane_count);
        batch.vy -= @as(Vec4, @splat(item_gravity_per_tick));
        batch.px += batch.vx;
        batch.py += batch.vy;
        batch.pz += batch.vz;
        resolveGround(clock, blocks, items, &batch, lane_count);
        applyItemFriction(&batch);
        self.commitPhysicsBatch(items, &batch, lane_count, outputs);
    }

    const Vec4 = @Vector(4, f64);

    const PhysicsBatch = struct {
        indices: [4]u16,
        previous_x: Vec4,
        previous_y: Vec4,
        previous_z: Vec4,
        px: Vec4,
        py: Vec4,
        pz: Vec4,
        vx: Vec4,
        vy: Vec4,
        vz: Vec4,
        grounded: [4]bool = @splat(false),
    };

    fn loadPhysicsBatch(items: *const entity_store.ItemEntities, active_start: usize, lane_count: usize) PhysicsBatch {
        var result: PhysicsBatch = undefined;
        result.indices = @splat(items.active_indices[active_start]);
        for (0..lane_count) |lane| result.indices[lane] = items.active_indices[active_start + lane];
        inline for (0..4) |lane| {
            const index = result.indices[lane];
            result.px[lane] = items.position_x[index];
            result.py[lane] = items.position_y[index];
            result.pz[lane] = items.position_z[index];
            result.vx[lane] = items.velocity_x[index];
            result.vy[lane] = items.velocity_y[index];
            result.vz[lane] = items.velocity_z[index];
        }
        result.previous_x = result.px;
        result.previous_y = result.py;
        result.previous_z = result.pz;
        result.grounded = @splat(false);
        return result;
    }

    fn resolveGround(clock: *const world_clock.Clock, blocks: *block_store.Blocks, items: *const entity_store.ItemEntities, batch: *PhysicsBatch, lane_count: usize) void {
        var moved_y: [4]f64 = batch.py;
        const moved_x: [4]f64 = batch.px;
        const moved_z: [4]f64 = batch.pz;
        for (0..lane_count) |lane| {
            const position = geometry.Vec3{ .x = moved_x[lane], .y = moved_y[lane], .z = moved_z[lane] };
            const chunk = geometry.ChunkPos{
                .x = @divFloor(geometry.blockCoord(position.x), 16),
                .z = @divFloor(geometry.blockCoord(position.z), 16),
            };
            const world = items.worlds[batch.indices[lane]];
            if (blocks.residentChunk(world, chunk) == null) {
                _ = blocks.generatedHeightChunkRef(world, chunk, clock.tick);
            }
            if (entity_store.itemGroundY(blocks, world, position)) |ground_y| {
                if (moved_y[lane] <= ground_y) {
                    moved_y[lane] = ground_y;
                    batch.grounded[lane] = true;
                }
            }
        }
        batch.py = moved_y;
    }

    fn applyItemFriction(batch: *PhysicsBatch) void {
        const grounded: @Vector(4, bool) = batch.grounded;
        const friction = @select(f64, grounded, @as(Vec4, @splat(item_ground_friction)), @as(Vec4, @splat(item_air_friction)));
        batch.vx *= friction;
        batch.vz *= friction;
        batch.vy *= @as(Vec4, @splat(item_air_friction));
        batch.vy = @select(f64, grounded, batch.vy * @as(Vec4, @splat(-0.5)), batch.vy);
    }

    fn commitPhysicsBatch(self: *ItemEntities, items: *entity_store.ItemEntities, batch: *const PhysicsBatch, lane_count: usize, outputs: *Packets) void {
        const final_x: [4]f64 = batch.px;
        const final_y: [4]f64 = batch.py;
        const final_z: [4]f64 = batch.pz;
        const final_vx: [4]f64 = batch.vx;
        const final_vy: [4]f64 = batch.vy;
        const final_vz: [4]f64 = batch.vz;
        const old_x: [4]f64 = batch.previous_x;
        const old_y: [4]f64 = batch.previous_y;
        const old_z: [4]f64 = batch.previous_z;
        for (0..lane_count) |lane| {
            const index = batch.indices[lane];
            items.position_x[index] = final_x[lane];
            items.position_y[index] = final_y[lane];
            items.position_z[index] = final_z[lane];
            items.velocity_x[index] = final_vx[lane];
            items.velocity_y[index] = final_vy[lane];
            items.velocity_z[index] = final_vz[lane];
            items.on_ground[index] = batch.grounded[lane];
            items.age_ticks[index] +%= 1;
            if (items.pickup_delay_ticks[index] != 0 and items.pickup_delay_ticks[index] != infinite_pickup_delay)
                items.pickup_delay_ticks[index] -= 1;
            items.updateBucket(index);
            const crossed_block = geometry.blockCoord(old_x[lane]) != geometry.blockCoord(final_x[lane]) or
                geometry.blockCoord(old_y[lane]) != geometry.blockCoord(final_y[lane]) or
                geometry.blockCoord(old_z[lane]) != geometry.blockCoord(final_z[lane]);
            const merge_interval: u32 = if (crossed_block) 2 else 40;
            self.merge_due[index] = items.age_ticks[index] % merge_interval == 0;
            const moved = (final_x[lane] - old_x[lane]) * (final_x[lane] - old_x[lane]) +
                (final_y[lane] - old_y[lane]) * (final_y[lane] - old_y[lane]) +
                (final_z[lane] - old_z[lane]) * (final_z[lane] - old_z[lane]);
            const speed = final_vx[lane] * final_vx[lane] + final_vy[lane] * final_vy[lane] + final_vz[lane] * final_vz[lane];
            if (moved > 0.000001 or speed > 0.000001) outputs.item_moved(index);
        }
    }

    fn tryStackItemEntity(
        self: *ItemEntities,
        items: *entity_store.ItemEntities,
        item_index: u16,
        outputs: *Packets,
    ) bool {
        const stack = &items.stacks[item_index];
        if (!items.active[item_index] or
            stack.isEmpty() or
            stack.count >= player_store.maxStackSize(stack.item_id) or
            items.pickup_delay_ticks[item_index] == infinite_pickup_delay) return false;
        const cell = entity_store.itemSpatialCell(items.position(item_index));
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const world = items.worlds[item_index];
                var other_node = items.bucket_heads[entity_store.itemSpatialBucketForCell(world, cell.x + dx, cell.z + dz)];
                for (0..config.max_item_entities) |_| {
                    if (other_node == entity_store.item_entity_sentinel) break;
                    const other_index = other_node;
                    other_node = items.next_in_bucket[other_index];
                    if (other_index == item_index) continue;
                    const other_stack = &items.stacks[other_index];
                    if (!items.active[other_index] or
                        !items.worlds[other_index].eql(world) or
                        items.cell_x[other_index] != cell.x + dx or
                        items.cell_z[other_index] != cell.z + dz or
                        items.pickup_delay_ticks[other_index] == infinite_pickup_delay or
                        !player_store.sameStackKind(stack.*, other_stack.*) or
                        @as(u16, stack.count) + @as(u16, other_stack.count) > player_store.maxStackSize(stack.item_id) or
                        !itemMergeBoxesOverlap(items.position(item_index), items.position(other_index))) continue;

                    const survivor, const removed = if (stack.count > other_stack.count)
                        .{ item_index, other_index }
                    else
                        .{ other_index, item_index };
                    const survivor_stack = &items.stacks[survivor];
                    const removed_stack = &items.stacks[removed];
                    survivor_stack.count += removed_stack.count;
                    items.age_ticks[survivor] = @min(
                        items.age_ticks[survivor],
                        items.age_ticks[removed],
                    );
                    items.pickup_delay_ticks[survivor] = @max(
                        items.pickup_delay_ticks[survivor],
                        items.pickup_delay_ticks[removed],
                    );
                    const entity_id = items.entity_ids[removed];
                    items.remove(removed);
                    outputs.entity_destroyed(entity_id);
                    self.scheduleItemMetadata(survivor);
                    plugin_profiler.countTrace(ItemEntityTrace.stack_merges, 1);
                    return true;
                } else @panic("item entity spatial bucket contains a cycle");
            }
        }
        return false;
    }

    fn itemMergeBoxesOverlap(a: geometry.Vec3, b: geometry.Vec3) bool {
        return @abs(a.x - b.x) <= 0.75 and
            @abs(a.y - b.y) <= 0.25 and
            @abs(a.z - b.z) <= 0.75;
    }

    fn scheduleItemMetadata(self: *ItemEntities, index: u16) void {
        for (self.pending_metadata[0..self.pending_metadata_count]) |pending|
            if (pending == index) return;
        if (self.pending_metadata_count == self.pending_metadata.len) return;
        self.pending_metadata[self.pending_metadata_count] = index;
        self.pending_metadata_count += 1;
    }

    fn tryPickupItemEntity(players: *player_store.Players, items: *entity_store.ItemEntities, item_index: u16, outputs: *Packets) bool {
        if (!items.active[item_index]) return false;
        for (players.activeSlots()) |slot| {
            const player = &players.records[slot];
            if (player.state != .play or
                !player.world.eql(items.worlds[item_index]) or
                !playerCanPickupItem(player, items.position(item_index))) continue;
            var remaining = items.stacks[item_index];
            const count_before = remaining.count;
            player_store.moveStackInto(&player.hotbar, &remaining);
            player_store.moveStackInto(&player.main_inventory, &remaining);
            if (remaining.count == count_before) continue;
            const item_entity_id = items.entity_ids[item_index];
            const picked_up_count = items.stacks[item_index].count - remaining.count;
            outputs.item_collected(.{ .item_entity_id = item_entity_id, .collector_entity_id = player.entity_id, .count = picked_up_count });
            outputs.inventory_changed(slot);
            if (remaining.isEmpty()) {
                items.remove(item_index);
                outputs.entity_destroyed(item_entity_id);
            } else {
                items.stacks[item_index] = remaining;
                outputs.item_metadata_changed(item_index);
            }
            plugin_profiler.countTrace(ItemEntityTrace.player_pickups, picked_up_count);
            return true;
        }
        return false;
    }
};
