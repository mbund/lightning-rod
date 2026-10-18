const persistent_records = @import("records");
const std = @import("std");
const inventories = @import("inventories");
const lightning_rod = @import("lightning_rod");
const entities = @import("entities");
const worlds = @import("worlds");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const ItemPhysics = @import("item_physics.zig").ItemPhysics;
const ItemMerging = @import("item_merging.zig").ItemMerging;
const ItemPickup = @import("item_pickup.zig").ItemPickup;
const Players = @import("players.zig").Players;
const item = @import("item.zig");
const Items = @import("items.zig").Items;

const assert = std.debug.assert;

pub const ItemTick = struct {
    pub const id = "minecraft:item_tick";

    pub const Configuration = struct { merge_candidates: usize = 4096 };

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
    };

    deps: Dependencies,
    stepped: u64 = 0,
    merged: u64 = 0,
    merge_candidates: usize,
    merge_after: entities.Id = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ItemTick {
        const self = try allocator.create(ItemTick);
        if (config.merge_candidates == 0) return error.InvalidConfiguration;
        self.* = .{ .deps = deps, .merge_candidates = config.merge_candidates };
        return self;
    }

    pub fn tick(self: *ItemTick) !void {
        const dropped = self.deps.dropped;
        var merge_remaining = self.merge_candidates;
        const active = dropped.nearby(self.deps.players, self.deps.players.config.simulation_distance);
        var start_low: usize = 0;
        var start_high = active.len;
        while (start_low < start_high) {
            const middle = start_low + (start_high - start_low) / 2;
            if (active[middle] <= self.merge_after) start_low = middle + 1 else start_high = middle;
        }
        // Start after the last merge candidate so dense, unmergeable piles cannot starve others.
        var iterator = dropped.iterate(active);
        defer iterator.deinit();
        iterator.start = start_low;
        while (try iterator.next()) |records| for (records) |record| {
            const entity = record.id;
            const row = .{ .id = entity };
            var metadata = try record.read();
            if (!metadata.alive) continue;

            var body = (try record.body.read()) orelse return error.Corrupt;
            metadata.ticks +%= 1;

            if (metadata.pickup_delay > 0 and metadata.pickup_delay != 32767) metadata.pickup_delay -= 1;
            const advanced = try self.deps.physics.advance(@intCast(ItemEntities.networkId(row.id)), metadata.ticks, body, metadata.on_ground);
            metadata.on_ground = advanced.on_ground;

            if (!std.meta.eql(body, advanced.body)) {
                try dropped.move(record, body, advanced.body);
                metadata.revision += 1;
                body = advanced.body;
            }

            self.stepped += 1;
            const interval: u32 = if (advanced.crossed_block) 2 else 40;
            if (merge_remaining != 0 and metadata.ticks % interval == 0 and metadata.age != -32768 and metadata.age < 6000 and metadata.pickup_delay != 32767) {
                const held = (try self.deps.inventories.get(ItemEntities.slot(body))).stack orelse return error.Corrupt;
                const maximum = try self.deps.items.stackLimit(held);
                if (held.count < maximum) {
                    const low: [3]i32 = .{ @intFromFloat(@floor((body.position[0] - 0.75) / 16)), @intFromFloat(@floor((body.position[1] - 0.25) / 16)), @intFromFloat(@floor((body.position[2] - 0.75) / 16)) };
                    const high: [3]i32 = .{ @intFromFloat(@floor((body.position[0] + 0.75) / 16)), @intFromFloat(@floor((body.position[1] + 0.25) / 16)), @intFromFloat(@floor((body.position[2] + 0.75) / 16)) };
                    var x = low[0];

                    neighbors: while (x <= high[0]) : (x += 1) {
                        var z = low[2];

                        while (z <= high[2]) : (z += 1) {
                            var y = low[1];

                            while (y <= high[1]) : (y += 1) {
                                var cell = body;
                                cell.position = .{ @as(f64, @floatFromInt(x)) * 16, @as(f64, @floatFromInt(y)) * 16, @as(f64, @floatFromInt(z)) * 16 };
                                const prefix = ItemEntities.spatialKey(0, cell);
                                var after = prefix;
                                var position: persistent_records.ScanCursor = .{ .after = &after, .after_len = 17 };
                                var keys: [16][25]u8 = undefined;
                                var values: [16][54]u8 = undefined;
                                var entries: [16]persistent_records.ScanEntry = undefined;

                                for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };

                                var more = true;

                                while (more) {
                                    const batch = try dropped.cache.scan(&position, &entries);
                                    more = batch.more;

                                    for (entries[0..batch.count]) |entry| {
                                        if (merge_remaining == 0) break :neighbors;
                                        merge_remaining -= 1;
                                        self.merge_after = entity;
                                        if (entry.key_len != 25 or !std.mem.eql(u8, entry.key[0..17], prefix[0..17])) {
                                            more = false;
                                            break;
                                        }

                                        const other_id = std.mem.readInt(u64, entry.key[17..25], .big);
                                        if (other_id == row.id) continue;

                                        var other_meta = try dropped.get(other_id);
                                        if (!other_meta.alive) continue;

                                        const other = (try self.deps.entities.get(other_id)) orelse return error.Corrupt;
                                        assert(other.world == body.world);
                                        if (@abs(body.position[0] - other.position[0]) >= 0.75 or @abs(body.position[1] - other.position[1]) >= 0.25 or @abs(body.position[2] - other.position[2]) >= 0.75)
                                            continue;

                                        var contents: [2]inventories.Contents = undefined;
                                        try self.deps.inventories.getMany(&.{ ItemEntities.slot(body), ItemEntities.slot(other) }, &contents);
                                        const first, const second = contents;
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
                                            if (merged.destination_is_first) try dropped.retire(other_id, other, &other_meta) else try dropped.retire(row.id, body, &metadata);
                                        }

                                        try dropped.put(other_id, other_meta);
                                        self.merged += 1;
                                        if (!metadata.alive) break :neighbors;
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
                try dropped.retire(row.id, body, &metadata);
            }

            record.write(metadata);
        };
    }
};
