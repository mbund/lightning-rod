const std = @import("std");
const inventories = @import("inventories");
const entities = @import("entities");
const worlds = @import("worlds");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const ItemMerging = @import("vanilla_item_entities").item_merging.ItemMerging;
const ItemPickup = @import("item_pickup.zig").ItemPickup;
const Players = @import("players").players.Players;
const Items = @import("vanilla_items").items.Items;
const Dimensions = @import("vanilla_content").dimensions.Dimensions;
const ClientRegistries = @import("vanilla_content").client_registries.ClientRegistries;
const hazards_module = @import("item_hazards.zig");
const work = @import("lightning_rod").system.work;

const assert = std.debug.assert;

pub const ItemTick = struct {
    pub const id = "minecraft:item_tick";

    pub const Configuration = struct { merge_work: work.Limits = .{ .guaranteed = .{ .operations = 1 }, .burst = .{ .operations = 4096 } } };

    pub const Dependencies = struct {
        dropped: *ItemEntities,
        physics: *ItemPhysics,
        merging: *ItemMerging,
        pickup: *ItemPickup,
        players: *Players,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        worlds: *worlds.Worlds,
        dimensions: *Dimensions,
        client: *ClientRegistries,
    };

    deps: Dependencies,
    stepped: u64 = 0,
    merged: u64 = 0,
    merge_work: work.Limits,
    merge_after: entities.Id = 0,
    /// The world the last item was in and whether its dimension is ultrawarm, as items come in
    /// runs of one world.
    last_world: ?u32 = null,
    last_ultrawarm: bool = false,
    query: ItemEntities.Query,
    hazards: hazards_module.Hazards,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ItemTick {
        try config.merge_work.validate(deps.dropped.residents.len, .{ .operations = 1 });
        if ((try config.merge_work.maximum(1)).bytes != 0) return error.InvalidWorkLimits;
        const self = try allocator.create(ItemTick);
        self.* = .{
            .deps = deps,
            .merge_work = config.merge_work,
            .query = try ItemEntities.Query.init(allocator, deps.dropped, deps.players),
            .hazards = try .init(allocator, .{
                .chunks = deps.physics.deps.chunks,
                .blocks = deps.physics.deps.blocks,
                .items = deps.items,
                .client = deps.client,
                .players = deps.players,
                .worlds = deps.worlds,
                .inventories = deps.inventories,
            }),
        };
        return self;
    }

    /// Whether lava flows strongly in the world, as in the nether, which pushes items harder.
    fn ultrawarm(self: *ItemTick, world: u32) !bool {
        if (self.last_world != world) {
            const entry = self.deps.worlds.get(world) orelse return error.Corrupt;
            self.last_ultrawarm = if (self.deps.dimensions.get(entry.dimension.name)) |dimension| dimension.ultrawarm else false;
            self.last_world = world;
        }
        return self.last_ultrawarm;
    }

    pub fn tick(self: *ItemTick) !void {
        const dropped = self.deps.dropped;
        var burst = self.merge_work.burst;
        const active = self.query.read(self.deps.players.config.simulation_distance);
        var start_low: usize = 0;
        var start_high = active.len;
        while (start_low < start_high) {
            const middle = start_low + (start_high - start_low) / 2;
            if (active[middle] <= self.merge_after) start_low = middle + 1 else start_high = middle;
        }
        // Start after the last merge candidate so dense, unmergeable piles cannot starve others.
        var neighborhood = self.deps.physics.readWindow();
        defer neighborhood.deinit();
        self.hazards.window = &neighborhood;
        defer self.hazards.window = null;
        defer self.hazards.endTick();
        var iterator = dropped.iterate(active);
        defer iterator.deinit();
        iterator.start = start_low;
        while (try iterator.next()) |records| for (records) |record| {
            const entity = record.id;
            var metadata = try record.read();
            if (!metadata.alive) continue;

            var body = (try record.body.read()) orelse return error.Corrupt;
            metadata.ticks +%= 1;

            // Entity.baseTick: pushed by currents, then burning down.
            var pushed = body;
            const fluids = try self.deps.physics.push(&neighborhood, &pushed, try self.ultrawarm(body.world));
            var subject: hazards_module.Subject = .{
                .world = body.world,
                .position = body.position,
                .old_position = body.position,
                .velocity = pushed.velocity,
                .on_ground = metadata.on_ground,
                .fire_ticks = metadata.fire_ticks,
                .ticks_frozen = metadata.ticks_frozen,
                .health = metadata.health,
                .slot = ItemEntities.slot(body),
            };
            const was_burning = metadata.fire_ticks > 0;
            // Entity.isInLava, which is false on an entity's first tick.
            try self.hazards.burn(&subject, metadata.ticks > 1 and fluids.lava > 0);
            var advanced: ItemPhysics.Result = .{ .body = pushed, .on_ground = metadata.on_ground, .crossed_block = false };
            if (!subject.removed) {
                if (metadata.pickup_delay > 0 and metadata.pickup_delay != 32767) metadata.pickup_delay -= 1;
                advanced = try self.deps.physics.advance(&neighborhood, @intCast(entity), metadata.ticks, pushed, metadata.on_ground, fluids, metadata.stuck.multiplier(), hazards_module.Hook{ .hazards = &self.hazards, .subject = &subject });
                if (advanced.moved) metadata.stuck = ItemEntities.Stuck.of(subject.stuck);
            }
            metadata.on_ground = advanced.on_ground;
            metadata.fire_ticks = subject.fire_ticks;
            metadata.ticks_frozen = @intCast(subject.ticks_frozen);
            metadata.health = subject.health;
            // Burning shows on the item, and a hurt item sends its velocity again.
            if (subject.hurt or was_burning != (metadata.fire_ticks > 0)) metadata.revision += 1;

            if (!std.meta.eql(body, advanced.body)) {
                try dropped.move(record, body, advanced.body);
                metadata.revision += 1;
                body = advanced.body;
            }

            if (subject.removed) {
                // ItemEntity.hurtServer: an item with no health left is destroyed.
                const held = try self.deps.inventories.get(ItemEntities.slot(body));
                const removed = try self.deps.inventories.set(ItemEntities.slot(body), held.revision, null);
                assert(removed);
                try dropped.retire(entity, body, &metadata);
                record.write(metadata);
                continue;
            }

            self.stepped += 1;
            var guaranteed = self.merge_work.guaranteed;
            const allowance: work.Allowance = .{ .guaranteed = &guaranteed, .burst = &burst };
            var merge_remaining = guaranteed.operations + burst.operations;
            const interval: u32 = if (advanced.crossed_block) 2 else 40;
            if (merge_remaining != 0 and metadata.ticks % interval == 0 and metadata.age != -32768 and metadata.age < 6000 and metadata.pickup_delay != 32767) {
                if (!dropped.fullStack(record)) {
                    const low: [3]i32 = .{ @intFromFloat(@floor((body.position[0] - 0.75) / 16)), @intFromFloat(@floor((body.position[1] - 0.25) / 16)), @intFromFloat(@floor((body.position[2] - 0.75) / 16)) };
                    const high: [3]i32 = .{ @intFromFloat(@floor((body.position[0] + 0.75) / 16)), @intFromFloat(@floor((body.position[1] + 0.25) / 16)), @intFromFloat(@floor((body.position[2] + 0.75) / 16)) };
                    var x = low[0];

                    neighbors: while (x <= high[0]) : (x += 1) {
                        var z = low[2];

                        while (z <= high[2]) : (z += 1) {
                            var y = low[1];

                            while (y <= high[1]) : (y += 1) {
                                var after: entities.Id = 0;
                                while (merge_remaining != 0) {
                                    var candidate_ids: [16]entities.Id = undefined;
                                    const capacity = @min(candidate_ids.len, dropped.cache.entries.len / 4, self.deps.entities.cache.entries.len / 2, self.deps.inventories.cache.entries.len - 1, merge_remaining);
                                    assert(capacity > 0);
                                    const batch = dropped.inSection(.{ .world = body.world, .x = x, .y = y, .z = z }, &after, candidate_ids[0..capacity]);
                                    if (batch.len == 0) break;
                                    const shared = burst.operations;
                                    const admitted = allowance.take(.{ .operations = batch.len });
                                    assert(admitted);
                                    merge_remaining = guaranteed.operations + burst.operations;
                                    if (burst.operations != shared) self.merge_after = entity;
                                    var count: usize = 0;
                                    for (batch) |candidate_id| {
                                        if (candidate_id == entity) continue;
                                        candidate_ids[count] = candidate_id;
                                        count += 1;
                                    }
                                    if (count == 0) continue;
                                    var metadata_leases: [16]ItemEntities.MetadataLease = undefined;
                                    var metadata_values: [16]ItemEntities.Metadata = undefined;
                                    try dropped.acquireMetadataMany(candidate_ids[0..count], metadata_leases[0..count]);
                                    var metadata_count = count;
                                    defer for (metadata_leases[0..metadata_count]) |lease| lease.release();
                                    for (metadata_leases[0..count], metadata_values[0..count]) |lease, *value| value.* = try lease.read();
                                    var accepted: usize = 0;
                                    for (candidate_ids[0..count], metadata_leases[0..count], metadata_values[0..count]) |candidate_id, lease, value| {
                                        if (!value.alive or value.owner != metadata.owner or value.age == -32768 or value.age >= 6000 or value.pickup_delay == 32767) {
                                            lease.release();
                                            continue;
                                        }
                                        candidate_ids[accepted] = candidate_id;
                                        metadata_leases[accepted] = lease;
                                        metadata_values[accepted] = value;
                                        accepted += 1;
                                    }
                                    metadata_count = accepted;
                                    count = accepted;
                                    if (count == 0) continue;
                                    var body_leases: [16]entities.Entities.Lease = undefined;
                                    var bodies: [16]entities.State = undefined;
                                    try self.deps.entities.acquireMany(candidate_ids[0..count], body_leases[0..count]);
                                    defer for (body_leases[0..count]) |lease| lease.release();
                                    var mapping: [16]usize = undefined;
                                    var slots: [17]inventories.Slot = undefined;
                                    var contents: [17]inventories.Contents = undefined;
                                    slots[0] = ItemEntities.slot(body);
                                    accepted = 0;
                                    for (body_leases[0..count], bodies[0..count], 0..) |lease, *other, index| {
                                        other.* = (try lease.read()) orelse return error.Corrupt;
                                        assert(other.world == body.world);
                                        if (@abs(body.position[0] - other.position[0]) >= 0.75 or @abs(body.position[1] - other.position[1]) >= 0.25 or @abs(body.position[2] - other.position[2]) >= 0.75) continue;
                                        mapping[accepted] = index;
                                        slots[accepted + 1] = ItemEntities.slot(other.*);
                                        accepted += 1;
                                    }
                                    if (accepted == 0) continue;
                                    try self.deps.inventories.getMany(slots[0 .. accepted + 1], contents[0 .. accepted + 1]);
                                    var first = contents[0];
                                    const held = first.stack orelse return error.Corrupt;
                                    const maximum = try dropped.mergeLimit(record, held);
                                    if (held.count >= maximum) break :neighbors;
                                    for (mapping[0..accepted], contents[1..][0..accepted]) |index, second| {
                                        const other_id = candidate_ids[index];
                                        const other = bodies[index];
                                        var other_meta = metadata_values[index];
                                        const candidate: ItemEntities.Record = .{ .id = other_id, .metadata = metadata_leases[index], .body = body_leases[index] };
                                        if (first.stack == null or second.stack == null) return error.Corrupt;
                                        if (!inventories.Stack.sameItem(first.stack.?, second.stack.?)) continue;
                                        const merged = self.deps.merging.merge(
                                            .{
                                                .stack = first.stack.?,
                                                .maximum_stack = maximum,
                                                .age = metadata.age,
                                                .pickup_delay = metadata.pickup_delay,
                                                .owner = metadata.owner,
                                            },
                                            .{
                                                .stack = second.stack.?,
                                                .maximum_stack = maximum,
                                                .age = other_meta.age,
                                                .pickup_delay = other_meta.pickup_delay,
                                                .owner = other_meta.owner,
                                            },
                                        ) orelse continue;
                                        const remainder = if (merged.source) |source| source.stack else null;
                                        const committed = try self.deps.inventories.editMany(&.{
                                            .{
                                                .slot = ItemEntities.slot(body),
                                                .revision = first.revision,
                                                .stack = if (merged.destination_is_first) merged.destination.stack else remainder,
                                            },
                                            .{
                                                .slot = ItemEntities.slot(other),
                                                .revision = second.revision,
                                                .stack = if (merged.destination_is_first) remainder else merged.destination.stack,
                                            },
                                        });
                                        assert(committed);
                                        metadata.revision += 1;
                                        other_meta.revision += 1;
                                        const destination = if (merged.destination_is_first) &metadata else &other_meta;
                                        destination.age = merged.destination.age;
                                        destination.pickup_delay = merged.destination.pickup_delay;

                                        if (merged.source == null) {
                                            if (merged.destination_is_first) try dropped.retire(other_id, other, &other_meta) else try dropped.retire(entity, body, &metadata);
                                        }

                                        candidate.write(other_meta);
                                        first.revision += 1;
                                        first.stack = if (merged.destination_is_first) merged.destination.stack else remainder;
                                        if (metadata.alive) _ = try dropped.mergeLimit(record, first.stack.?);
                                        if (other_meta.alive) _ = try dropped.mergeLimit(candidate, if (merged.destination_is_first) remainder.? else merged.destination.stack);
                                        self.merged += 1;
                                        if (!metadata.alive) break :neighbors;
                                        if (first.stack.?.count >= maximum) break :neighbors;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (metadata.alive and metadata.age != -32768) metadata.age += 1;
            const world = self.deps.worlds.get(body.world) orelse return error.UnknownWorld;
            const void_y: f64 = @floatFromInt(world.dimension.minimumSection() * 16 - 64);

            if (metadata.alive and (metadata.age >= 6000 or body.position[1] < void_y)) {
                const held = try self.deps.inventories.get(ItemEntities.slot(body));
                const removed = try self.deps.inventories.set(ItemEntities.slot(body), held.revision, null);
                assert(removed);
                try dropped.retire(entity, body, &metadata);
            }

            record.write(metadata);
        };
    }
};
