const audience_storage = @import("audience.zig");
const sparse_sets = @import("lightning_rod").system.sparse_sets;
const bit_sets = @import("lightning_rod").system.bit_sets;
const std = @import("std");
const Selection = @import("item_selection.zig").Selection;
const Items = @import("items.zig").Items;
const inventories = @import("inventories");
const entities = @import("entities");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const game_data = @import("game_data");
const item_packets = @import("item_packets.zig");
const packets = @import("minecraft_packets");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_9 = @import("wire_1_21_9");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const ItemTick = @import("item_tick.zig").ItemTick;
const Players = @import("players.zig").Players;
const Streaming = @import("streaming.zig").Streaming;

const assert = std.debug.assert;

pub const ItemReplication = struct {
    pub const id = "minecraft:item_replication";

    pub const Configuration = struct { audience_words: usize = 4096 };

    const tracking_distance = 96;

    pub const Dependencies = struct {
        dropped: *ItemEntities,
        item_tick: *ItemTick,
        players: *Players,
        streaming: *Streaming,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
    };

    const Spawn = struct {
        entity_id: i32,
        uuid: u128,
        position: minecraft.Position,
        velocity: [3]f64,
    };

    const View = struct {
        entity: entities.Id = 0,
        revision: u64 = 0,
        collection: u64 = 0,
        spawned: audience_storage.Row = .{},
        dirty: audience_storage.Row = .{},
        collected: audience_storage.Row = .{},
        inventory_revision: u64 = 0,
        inventory_owner: ?u128 = null,
        inventory_dirty: u64 = 1,
        contents: inventories.Contents = .{},
        interested: audience_storage.Row = .{},
        collecting: bool = false,
        stacks: audience_storage.Row = .{},
        pending: audience_storage.Row = .{},
    };

    const Connection = struct {
        generation: u32 = 0,
        life: u32 = 0,
        world: u32 = 0,
        position: [2]f64 = @splat(0),
        ready: bool = false,
    };

    const Phase = enum { spawn, stack, position, collect, remove };

    const Batch = struct {
        const Delivery = struct { index: u32, phase: Phase, receipt: sessions.Service.Broadcast.Receipt };
        owner: *ItemReplication,
        audience: sparse_sets.Workspace.RowView,
        deliveries: [sessions.Service.batch_max]Delivery = undefined,
        count: usize = 0,

        fn prepare(self: *Batch, audience: bit_sets.Set, packets_per_group: usize) !bool {
            assert(audience.any() and packets_per_group > 0 and packets_per_group <= sessions.Service.batch_max);
            const owner = self.owner;
            const broadcast = &owner.broadcast;
            if (broadcast.active and (!self.audience.view().eql(audience) or self.count == self.deliveries.len or
                packets_per_group * owner.deps.sessions.config.protocols.len > broadcast.entries.len - broadcast.count)) self.flush();
            if (broadcast.active) return true;
            assert(self.count == 0);
            var remaining = audience.iterator();
            var count: usize = 0;
            while (remaining.next()) |index| {
                const player = owner.deps.players.records[index];
                owner.recipients[count] = .{ .handle = player.handle.?, .protocol = player.protocol };
                count += 1;
            }
            broadcast.begin(owner.recipients[0..count]) catch |err| switch (err) {
                error.Backpressured => return false,
                else => return err,
            };
            self.audience.copy(audience);
            return true;
        }

        fn append(self: *Batch, index: u32, phase: Phase, receipt: sessions.Service.Broadcast.Receipt) void {
            assert(self.owner.broadcast.active and self.count < self.deliveries.len);
            assert(index < self.owner.views.len and self.owner.views[index].entity != 0);
            assert(receipt.owner == &self.owner.broadcast and receipt.generation == self.owner.broadcast.generation);
            self.deliveries[self.count] = .{ .index = index, .phase = phase, .receipt = receipt };
            self.count += 1;
        }

        fn flush(self: *Batch) void {
            const owner = self.owner;
            const broadcast = &owner.broadcast;
            if (!broadcast.active) {
                assert(self.count == 0);
                return;
            }
            assert(self.count > 0 and self.count <= self.deliveries.len);
            broadcast.commit();
            for (self.deliveries[0..self.count]) |delivery| {
                const delivered = broadcast.accepted(delivery.receipt);
                var unsupported = broadcast.unsupported(delivery.receipt).iterator();
                while (unsupported.next()) |index| {
                    owner.deps.sessions.disconnect(broadcast.handleAt(index));
                }
                const view = &owner.views[delivery.index];
                switch (delivery.phase) {
                    .spawn => {
                        view.spawned.unite(view.spawned.view(), delivered);
                        view.dirty.unite(view.dirty.view(), delivered);
                        view.stacks.subtract(view.stacks.view(), delivered);
                        view.collected.unite(view.collected.view(), delivered);
                    },
                    .stack => view.stacks.subtract(view.stacks.view(), delivered),
                    .position => view.dirty.subtract(view.dirty.view(), delivered),
                    .collect => view.collected.unite(view.collected.view(), delivered),
                    .remove => {
                        view.spawned.subtract(view.spawned.view(), delivered);
                        view.dirty.subtract(view.dirty.view(), delivered);
                        view.collected.subtract(view.collected.view(), delivered);
                        view.stacks.subtract(view.stacks.view(), delivered);
                    },
                }
            }
            broadcast.cancel();
            self.count = 0;
            self.audience.clear();
        }
    };

    deps: Dependencies,
    views: []View,
    presentation: u64 = 0,
    work: lightning_rod.system.IndexSet,
    retries: lightning_rod.system.IndexSet,
    pending: sparse_sets.Workspace.RowView,
    selections: sparse_sets.Workspace,
    view_sets: audience_storage.Matrix,
    connections: []Connection,
    tracked_connections: lightning_rod.system.IndexSet,
    recipients: []sessions.Service.Target,
    inventory_observer: *inventories.Inventories.Observer,
    broadcast: sessions.Service.Broadcast,
    selection: Selection,
    selection_candidates: lightning_rod.metrics.Counter,
    selection_nodes: lightning_rod.metrics.Counter,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*ItemReplication {
        const self = try allocator.create(ItemReplication);
        const connections = try allocator.alloc(Connection, deps.players.records.len);
        @memset(connections, .{});
        const views = try allocator.alloc(View, deps.dropped.residents.len);
        @memset(views, .{});
        const selections = try sparse_sets.Workspace.init(allocator, 28, connections.len);
        self.* = .{
            .pending = selections.row(0),
            .selections = selections,
            .view_sets = try audience_storage.Matrix.init(allocator, deps.players, try std.math.mul(usize, 6, views.len), config.audience_words, .recipients),
            .broadcast = try sessions.Service.Broadcast.init(allocator, deps.sessions, sessions.Service.batch_max * deps.sessions.config.protocols.len),
            .deps = deps,
            .work = try lightning_rod.system.IndexSet.init(allocator, views.len),
            .retries = try lightning_rod.system.IndexSet.init(allocator, views.len),
            .connections = connections,
            .tracked_connections = try lightning_rod.system.IndexSet.init(allocator, connections.len),
            .recipients = try allocator.alloc(sessions.Service.Target, connections.len),
            .views = views,
            .inventory_observer = try deps.inventories.observe(allocator, views.len),
            .selection = try Selection.init(allocator, connections.len * 4, views.len),
            .selection_candidates = try deps.dropped.deps.metrics.counter(.{ .name = "items.replication.selection.candidates", .description = "Spatial candidates examined by batched movement selection" }),
            .selection_nodes = try deps.dropped.deps.metrics.counter(.{ .name = "items.replication.selection.coverage_nodes", .description = "Coverage nodes updated or examined by batched movement selection" }),
        };
        for (0..views.len) |index| self.resetView(index, 0);
        return self;
    }

    fn resetView(self: *ItemReplication, index: usize, entity: entities.Id) void {
        const view = &self.views[index];
        view.* = .{ .entity = entity };
        inline for (.{ "spawned", "dirty", "collected", "interested", "stacks", "pending" }, 0..) |field, at| {
            @field(view, field) = self.view_sets.row(index * 6 + at);
            @field(view, field).clear();
        }
    }

    pub fn tick(self: *ItemReplication) !void {
        assert(self.selection.count == 0);
        const dropped = self.deps.dropped;
        if (dropped.ids.count() == 0) {
            assert(self.retries.count == 0);
            self.work.clear();
            self.pending.clear();
            return;
        }
        const service = self.deps.sessions;
        const visibility = self.deps.streaming.snapshotVisibility();
        const presentation_changed = self.presentation != self.deps.items.components.revision;
        self.presentation = self.deps.items.components.revision;
        const valid = self.selections.row(1);
        const reset = self.selections.row(2);
        const available = self.selections.row(3);
        valid.clear();
        reset.clear();
        available.clear();

        const reconsider = presentation_changed;
        for (self.deps.players.activeSlots()) |index| self.tracked_connections.insert(index);
        var observer_index: usize = 0;
        while (observer_index < self.tracked_connections.count) {
            const index = self.tracked_connections.indices[observer_index];
            const player = self.deps.players.records[index];
            const connection = &self.connections[index];
            if (player.handle == null) self.tracked_connections.remove(index) else observer_index += 1;
            const current: Connection = .{ .generation = if (player.handle) |handle| handle.generation else 0, .life = player.life, .world = player.world, .position = .{ player.position.x, player.position.z }, .ready = player.stage == .ready };
            const changed = connection.generation != current.generation or connection.life != current.life or connection.world != current.world or connection.ready != current.ready;
            if (changed or visibility.reset.contains(index)) {
                if (connection.ready) self.selectBounds(connection.world, .{ connection.position[0] - tracking_distance, connection.position[1] - tracking_distance }, .{ connection.position[0] + tracking_distance, connection.position[1] + tracking_distance });
                if (current.ready) self.selectBounds(current.world, .{ current.position[0] - tracking_distance, current.position[1] - tracking_distance }, .{ current.position[0] + tracking_distance, current.position[1] + tracking_distance });
            }
            if (!changed and current.ready and !std.meta.eql(connection.position, current.position)) self.selectMovement(current.world, connection.position, current.position);
            const replaced = connection.generation != current.generation or connection.life != current.life;
            connection.* = current;
            const handle = player.handle orelse continue;
            valid.insert(index);
            if (service.outputCredit(handle) != 0) available.insert(index);
            if (replaced) reset.insert(index);
        }

        const selection = self.selection.select(&dropped.spatial, &self.work);
        self.selection_candidates.add(selection.candidates);
        self.selection_nodes.add(selection.coverage_nodes);
        self.selectVisibility(visibility);
        if (!reconsider and self.work.count == 0 and dropped.changes.count == 0 and !self.pending.view().intersects(available.view())) return;
        if (reconsider) for (dropped.active.values()) |index| self.work.insert(index);
        for (dropped.changes.values()) |index| self.work.insert(index);
        dropped.changes.clear();
        for (self.retries.values()) |index| {
            if (self.views[index].pending.view().intersects(available.view())) self.work.insert(index);
        }
        if (self.work.count == 0) return;
        const selected = self.work.values();
        var outgoing: Batch = .{ .owner = self, .audience = self.selections.row(4) };
        defer if (self.broadcast.active) self.broadcast.cancel();
        var cursor: usize = 0;
        while (cursor < selected.len) {
            var ids: [16]entities.Id = undefined;
            var selected_count: usize = 0;
            while (cursor < selected.len and selected_count < ids.len) : (cursor += 1) {
                const index = selected[cursor];
                const resident_entry = dropped.residents[index];
                assert(resident_entry.id != 0);
                const view = &self.views[index];
                if (view.entity != resident_entry.id) {
                    if (view.inventory_owner) |owner| self.inventory_observer.unwatch(owner);
                    self.resetView(index, resident_entry.id);
                }
                var nearby = self.deps.players.nearby(resident_entry.world, .{
                    .x = @as(f64, @floatFromInt(resident_entry.x)) * 16,
                    .y = 0,
                    .z = @as(f64, @floatFromInt(resident_entry.z)) * 16,
                }, self.deps.players.config.render_distance);
                if ((!resident_entry.alive or nearby.next() == null) and !view.spawned.view().any()) {
                    self.retries.remove(index);
                    view.pending.clear();
                    view.interested.clear();
                    if (!resident_entry.alive) {
                        if (view.inventory_owner) |owner| self.inventory_observer.unwatch(owner);
                        try dropped.forget(resident_entry.id);
                        self.resetView(index, 0);
                    }
                    continue;
                }
                ids[selected_count] = resident_entry.id;
                selected_count += 1;
            }
            var iterator = dropped.iterate(ids[0..selected_count]);
            defer iterator.deinit();
            iterator.limit = @min(self.deps.inventories.cache.entries.len, self.deps.inventories.items.entries.len);
            while (try iterator.next()) |batch| {
                var interests: [16]sparse_sets.Workspace.RowView = undefined;
                for (&interests, 0..) |*row, at| {
                    row.* = self.selections.row(11 + at);
                    row.clear();
                }
                var slot_indices: [16]?usize = @splat(null);
                var slots: [16]inventories.Slot = undefined;
                var contents: [16]inventories.Contents = undefined;
                var slot_count: usize = 0;
                for (batch, 0..) |record, index| {
                    if (!(try record.read()).alive) continue;
                    const body = (try record.body.read()) orelse return error.Corrupt;
                    const position: minecraft.Position = .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] };
                    var candidates = self.deps.players.nearby(body.world, position, tracking_distance / 16);
                    while (candidates.next()) |player_index| {
                        const player = &self.deps.players.records[player_index];
                        if (player.handle == null or player.stage != .ready or body.world != player.world) continue;
                        if (@abs(body.position[0] - player.position.x) > tracking_distance or @abs(body.position[2] - player.position.z) > tracking_distance) continue;
                        if (visibility.visible(player_index, player, body.world, @intFromFloat(@floor(body.position[0] / 16)), @intFromFloat(@floor(body.position[2] / 16)))) interests[index].insert(player_index);
                    }
                    const view = &self.views[dropped.ids.get(record.id).?];
                    const slot = ItemEntities.slot(body);
                    if (interests[index].view().any() and view.inventory_owner == null) {
                        view.inventory_owner = slot.owner;
                        assert(slot.index == 0);
                        self.inventory_observer.watch(slot.owner, &.{0}, .{
                            .dirty = &view.inventory_dirty,
                            .changed = .{ .set = &self.work, .index = dropped.ids.get(record.id).? },
                        });
                    }
                    if (interests[index].view().intersects(available.view()) and view.inventory_dirty != 0) {
                        slot_indices[index] = slot_count;
                        slots[slot_count] = slot;
                        slot_count += 1;
                    }
                }
                try self.deps.inventories.getMany(slots[0..slot_count], contents[0..slot_count]);
                for (batch, slot_indices[0..batch.len]) |record, index| {
                    const at = index orelse continue;
                    const view = &self.views[dropped.ids.get(record.id).?];
                    view.contents = contents[at];
                    view.inventory_dirty = 0;
                }
                var definition_stacks: [16]inventories.Stack = undefined;
                var definition_records: [16]usize = undefined;
                var definitions: [16]Items.Prepared = undefined;
                var definition_lengths: [16]usize = @splat(0);
                var definition_views: [16]?Items.View = @splat(null);
                var definition_count: usize = 0;
                for (batch, 0..) |record, index| {
                    if (!interests[index].view().intersects(available.view())) continue;
                    const view = self.views[dropped.ids.get(record.id).?];
                    assert(view.inventory_dirty == 0);
                    const held = view.contents;
                    const spawned = self.selections.row(8);
                    spawned.intersect(view.spawned.view(), valid.view());
                    spawned.subtract(spawned.view(), reset.view());
                    const missing = self.selections.row(9);
                    missing.subtract(interests[index].view(), spawned.view());
                    if (!presentation_changed and held.revision == view.inventory_revision and
                        !view.stacks.view().intersects(interests[index].view()) and !missing.view().any()) continue;
                    const stack = held.stack orelse return error.Corrupt;
                    definition_stacks[definition_count] = stack;
                    definition_records[definition_count] = index;
                    definition_count += 1;
                }
                try self.deps.items.acquireMany(definition_stacks[0..definition_count], definitions[0..definition_count]);
                defer for (definitions[0..definition_count]) |definition| definition.release();
                for (definitions[0..definition_count], definition_records[0..definition_count]) |definition, index| {
                    definition_lengths[index] = definition.lease.read().?.len;
                    definition_views[index] = definition.view;
                }
                for (batch, 0..) |record, record_index| {
                    const slot_index = dropped.ids.get(record.id).?;
                    const view = &self.views[slot_index];
                    const row = .{ .id = record.id, .metadata = try record.read() };
                    view.spawned.intersect(view.spawned.view(), valid.view());
                    view.spawned.subtract(view.spawned.view(), reset.view());
                    view.dirty.intersect(view.dirty.view(), view.spawned.view());
                    view.collected.intersect(view.collected.view(), view.spawned.view());
                    view.stacks.intersect(view.stacks.view(), view.spawned.view());

                    if (view.revision != row.metadata.revision) {
                        view.dirty.unite(view.dirty.view(), view.spawned.view());
                        view.revision = row.metadata.revision;
                    }

                    if (view.collection != row.metadata.collection) {
                        view.collection = row.metadata.collection;
                        view.collected.clear();
                    }

                    const body = if (row.metadata.alive) (try record.body.read() orelse return error.Corrupt) else null;
                    const interested = interests[record_index].view();
                    view.interested.copy(interested);
                    view.collecting = row.metadata.collected > 0;
                    const held = view.contents;

                    if (presentation_changed or held.revision != view.inventory_revision) {
                        view.inventory_revision = held.revision;
                        view.stacks.unite(view.stacks.view(), view.spawned.view());
                    }

                    const entity_id = ItemEntities.networkId(row.id);
                    var queued = std.EnumSet(Phase).empty;
                    for (std.enums.values(Phase)) |phase| {
                        // Later phases use the actual admission result of spawn, stack, and collection updates.
                        const dependencies = switch (phase) {
                            .stack => std.EnumSet(Phase).initOne(.spawn),
                            .position => std.EnumSet(Phase).initMany(&.{ .spawn, .stack }),
                            .remove => std.EnumSet(Phase).initOne(.collect),
                            else => std.EnumSet(Phase).empty,
                        };
                        if (queued.intersectWith(dependencies).count() != 0) {
                            outgoing.flush();
                            queued = .empty;
                        }
                        const wanted = self.selections.row(6);
                        switch (phase) {
                            .spawn => wanted.subtract(interested, view.spawned.view()),
                            .stack => {
                                wanted.intersect(interested, view.spawned.view());
                                wanted.intersect(wanted.view(), view.stacks.view());
                            },
                            .position => {
                                wanted.intersect(interested, view.spawned.view());
                                wanted.intersect(wanted.view(), view.dirty.view());
                                wanted.subtract(wanted.view(), view.stacks.view());
                            },
                            .collect => {
                                wanted.clear();
                                if (row.metadata.collected > 0) wanted.subtract(view.spawned.view(), view.collected.view());
                            },
                            .remove => {
                                wanted.subtract(view.spawned.view(), interested);
                                if (row.metadata.collected > 0) wanted.intersect(wanted.view(), view.collected.view());
                            },
                        }
                        wanted.intersect(wanted.view(), available.view());
                        if (!wanted.view().any()) continue;
                        var capacity: usize = 128;
                        if (phase == .spawn or phase == .stack) {
                            assert(definition_lengths[record_index] != 0);
                            capacity = @max(128, definition_lengths[record_index] + 16 + self.deps.items.components.extra_bytes);
                        }
                        const eligible = self.selections.row(5);
                        eligible.clear();
                        var candidates = wanted.view().iterator();
                        while (candidates.next()) |index| {
                            const player = &self.deps.players.records[index];
                            const handle = player.handle orelse continue;
                            if (capacity > service.config.page_bytes) {
                                service.disconnect(handle);
                                continue;
                            }
                            if (!service.canSend(handle, capacity)) continue;
                            eligible.insert(index);
                        }
                        const personalized = (phase == .spawn or phase == .stack) and self.deps.items.components.personalized;
                        while (eligible.view().any()) {
                            const audience = self.selections.row(7);
                            audience.clear();
                            if (personalized) audience.insert(eligible.view().firstFrom(0).?) else audience.copy(eligible.view());
                            eligible.subtract(eligible.view(), audience.view());
                            if (!try outgoing.prepare(audience.view(), if (phase == .spawn) 4 else 1)) continue;
                            const recipient = self.deps.players.records[audience.view().firstFrom(0).?].uuid;
                            const receipt = switch (phase) {
                                .spawn => try self.deps.packets.broadcastGroup(&self.broadcast, .{ .{ writeSpawnLegacy, writeSpawnPacked }, writeItemStack }, null, null, .{
                                    .{Spawn{
                                        .entity_id = entity_id,
                                        .uuid = body.?.uuid,
                                        .position = .{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                        .velocity = body.?.velocity,
                                    }},
                                    .{ self.deps.items, entity_id, held.stack, recipient, definition_views[record_index] },
                                }, &.{ 128, capacity }),
                                .stack => try self.deps.packets.broadcastGroup(&self.broadcast, .{writeItemStack}, null, null, .{.{ self.deps.items, entity_id, held.stack, recipient, definition_views[record_index] }}, &.{capacity}),
                                .position => try self.deps.packets.broadcast(&self.broadcast, writePosition, null, null, .{
                                    entity_id,
                                    minecraft.Position{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                    minecraft.Position{ .x = body.?.velocity[0], .y = body.?.velocity[1], .z = body.?.velocity[2] },
                                    minecraft.Rotation{ .yaw = 0, .pitch = 0 },
                                    row.metadata.on_ground,
                                }, capacity),
                                .collect => try self.deps.packets.broadcast(&self.broadcast, writeCollect, null, null, .{ entity_id, row.metadata.collector, row.metadata.collected }, capacity),
                                .remove => try self.deps.packets.broadcast(&self.broadcast, writeRemove, null, null, .{entity_id}, capacity),
                            };
                            outgoing.append(slot_index, phase, receipt);
                            queued.insert(phase);
                        }
                    }
                }
            }
        }
        outgoing.flush();
        for (selected) |index| {
            const view = &self.views[index];
            if (view.entity == 0) continue;
            if (!dropped.residents[index].alive and !view.spawned.view().any()) {
                if (view.inventory_owner) |owner| self.inventory_observer.unwatch(owner);
                self.retries.remove(index);
                try dropped.forget(view.entity);
                self.resetView(index, 0);
                continue;
            }
            const interested = view.interested.view();
            view.pending.difference(interested, view.spawned.view());
            const changed = self.selections.row(8);
            changed.unite(view.stacks.view(), view.dirty.view());
            changed.intersect(changed.view(), interested);
            view.pending.unite(view.pending.view(), changed.view());
            if (view.inventory_dirty != 0) view.pending.unite(view.pending.view(), interested);
            if (view.collecting) {
                changed.subtract(view.spawned.view(), view.collected.view());
                view.pending.unite(view.pending.view(), changed.view());
            }
            if (view.pending.view().any()) self.retries.insert(index) else self.retries.remove(index);
        }
        assert(self.work.count == selected.len);
        self.work.clear();
        self.pending.clear();
        for (self.retries.values()) |index| self.pending.unite(self.pending.view(), self.views[index].pending.view());
    }

    fn selectVisibility(self: *ItemReplication, visibility: *const Streaming.Visibility) void {
        for (visibility.changed_words.values()) |word| {
            const player_index = word / visibility.words_per_player;
            if (visibility.reset.contains(player_index)) continue;
            const player = self.deps.players.records[player_index];
            if (player.handle == null or player.stage != .ready) continue;
            const center = visibility.viewCenter(player_index);
            const x = center.x - visibility.radius;
            const z = center.z - visibility.radius;
            var bits = visibility.changed[word];
            while (bits != 0) {
                const cell: i32 = @intCast((word % visibility.words_per_player) * 64 + @ctz(bits));
                bits &= bits - 1;
                if (cell >= visibility.side * visibility.side) continue;
                const column: [2]i32 = .{
                    x + @mod(@mod(cell, visibility.side) - @mod(x, visibility.side), visibility.side),
                    z + @mod(@divTrunc(cell, visibility.side) - @mod(z, visibility.side), visibility.side),
                };
                self.deps.dropped.selectColumns(player.world, column, column, &self.work);
            }
        }
    }

    fn selectMovement(self: *ItemReplication, world: u32, before: [2]f64, after: [2]f64) void {
        const minimum: [2]f64 = .{ @min(before[0], after[0]) - tracking_distance, @min(before[1], after[1]) - tracking_distance };
        const maximum: [2]f64 = .{ @max(before[0], after[0]) + tracking_distance, @max(before[1], after[1]) + tracking_distance };
        const crossed_column = @floor(before[0] / 16) != @floor(after[0] / 16) or @floor(before[1] / 16) != @floor(after[1] / 16);
        if (crossed_column) {
            self.selectBounds(world, .{ before[0] - tracking_distance, before[1] - tracking_distance }, .{ before[0] + tracking_distance, before[1] + tracking_distance });
            self.selectBounds(world, .{ after[0] - tracking_distance, after[1] - tracking_distance }, .{ after[0] + tracking_distance, after[1] + tracking_distance });
            return;
        }
        // Include both endpoints because the exact tracking boundary is inclusive.
        if (before[0] != after[0]) {
            self.selectBounds(world, minimum, .{ @max(before[0], after[0]) - tracking_distance, maximum[1] });
            self.selectBounds(world, .{ @min(before[0], after[0]) + tracking_distance, minimum[1] }, maximum);
        }
        if (before[1] != after[1]) {
            self.selectBounds(world, minimum, .{ maximum[0], @max(before[1], after[1]) - tracking_distance });
            self.selectBounds(world, .{ minimum[0], @min(before[1], after[1]) + tracking_distance }, maximum);
        }
    }

    fn selectBounds(self: *ItemReplication, world: u32, minimum: [2]f64, maximum: [2]f64) void {
        self.selection.append(world, minimum, maximum);
    }

    fn writeSpawnLegacy(packet: wire_1_21_5.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.item));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);

        const pitch = try z.pitch(0);
        const yaw = try pitch.yaw(0);
        const head = try yaw.headPitch(0);
        const data = try head.objectData(0);
        var velocity = try data.velocity();
        return (try velocity.advance(try packets.nested(.{writeVelocity}).write(try velocity.begin(), value.velocity))).finish();
    }

    fn writeVelocity(packet: wire_1_21_5.vec3i16.Writer, motion: [3]f64) !wire_1_21_5.vec3i16.Writer.Done {
        const x = try packet.x(encodedVelocity(motion[0]));
        const y = try x.y(encodedVelocity(motion[1]));
        return y.z(encodedVelocity(motion[2]));
    }

    fn writeSpawnPacked(packet: wire_1_21_9.play.toClient.packet_spawn_entity.Writer, registry: packets.Registry, value: Spawn) ![]u8 {
        const entity = try packet.entityId(value.entity_id);
        const uuid = try entity.objectUUID(value.uuid);
        const kind = try uuid.type(try registry.entityId(game_data.entities.item));
        const x = try kind.x(value.position.x);
        const y = try x.y(value.position.y);
        const z = try y.z(value.position.z);
        const velocity = try z.velocity(.{
            .x = @as(f64, @floatFromInt(encodedVelocity(value.velocity[0]))) / 8000,
            .y = @as(f64, @floatFromInt(encodedVelocity(value.velocity[1]))) / 8000,
            .z = @as(f64, @floatFromInt(encodedVelocity(value.velocity[2]))) / 8000,
        });
        const pitch = try velocity.pitch(0);
        const yaw = try pitch.yaw(0);
        const head = try yaw.headPitch(0);
        return (try head.objectData(0)).finish();
    }

    fn writeRemove(packet: wire_1_21_5.play.toClient.packet_entity_destroy.Writer, entity_id: i32) ![]u8 {
        const ids = try packet.entityIds(1);
        const entry = try ids.element(entity_id);
        return (try entry.finish()).finish();
    }

    fn writePosition(packet: wire_1_21_5.play.toClient.packet_sync_entity_position.Writer, entity_id: i32, at: minecraft.Position, motion: minecraft.Position, rotation: minecraft.Rotation, on_ground: bool) ![]u8 {
        const entity = try packet.entityId(entity_id);
        const x = try entity.x(at.x);
        const y = try x.y(at.y);
        const z = try y.z(at.z);
        const vx = try z.dx(motion.x);
        const vy = try vx.dy(motion.y);
        const vz = try vy.dz(motion.z);
        const yaw = try vz.yaw(rotation.yaw);
        return (try (try yaw.pitch(rotation.pitch)).onGround(on_ground)).finish();
    }

    fn writeCollect(packet: wire_1_21_5.play.toClient.packet_collect.Writer, item: i32, player: i32, count: i32) ![]u8 {
        const collected = try packet.collectedEntityId(item);
        const collector = try collected.collectorEntityId(player);
        return (try collector.pickupItemCount(count)).finish();
    }

    pub fn writeItemStack(packet: wire_1_21_5.play.toClient.packet_entity_metadata.Writer, registry: packets.Registry, store: *Items, entity: i32, stack: ?inventories.Stack, recipient: u128, view: ?Items.View) ![]u8 {
        var metadata = try (try packet.entityId(entity)).metadata();
        const done = try packets.nested(.{writeStackMetadata}).write(try metadata.begin(), .{ .registry = registry, .items = store, .stack = stack, .recipient = recipient, .view = view });
        return (try metadata.advance(done)).finish();
    }

    fn writeStackMetadata(packet: wire_1_21_5.entityMetadata.Writer, args: item_packets.SlotArguments) !wire_1_21_5.entityMetadata.Writer.Done {
        var entries = try packet.value(1);
        const entry = (try entries.next()).?;
        try entries.advance(try packets.nested(.{writeStackEntry}).write(entry, args));
        return entries.finish();
    }

    const StackEntry = wire_1_21_5.entityMetadataEntry.cases.value.item_stack.Writer;

    fn writeStackEntry(packet: StackEntry, args: item_packets.SlotArguments) !StackEntry.Done {
        const typed = try (try packet.key(8)).type();
        var item = try typed.value();
        return item.advance(try item_packets.writeSlot(try item.begin(), args));
    }
};

fn encodedVelocity(value: f64) i16 {
    assert(std.math.isFinite(value));
    return @intFromFloat(std.math.clamp(value, -3.9, 3.9) * 8000);
}
