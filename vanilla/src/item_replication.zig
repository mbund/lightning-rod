const std = @import("std");
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

    pub const Configuration = struct {};

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
        spawned: u256 = 0,
        dirty: u256 = 0,
        collected: u256 = 0,
        inventory_revision: u64 = 0,
        stacks: u256 = 0,
    };

    const Connection = struct {
        generation: u32 = 0,
        life: u32 = 0,
    };

    deps: Dependencies,
    views: []View,
    presentation: u64 = 0,
    connections: []Connection,
    recipients: []sessions.Handle,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemReplication {
        const self = try allocator.create(ItemReplication);
        const connections = try allocator.alloc(Connection, deps.players.records.len);
        @memset(connections, .{});
        const views = try allocator.alloc(View, deps.dropped.residents.len);
        @memset(views, .{});
        self.* = .{ .deps = deps, .connections = connections, .recipients = try allocator.alloc(sessions.Handle, connections.len), .views = views };
        return self;
    }

    pub fn tick(self: *ItemReplication) !void {
        const service = self.deps.sessions;
        self.deps.players.refreshSpatial();
        const presentation_changed = self.presentation != self.deps.items.components.revision;
        self.presentation = self.deps.items.components.revision;
        var valid: u256 = 0;
        var reset: u256 = 0;

        for (self.deps.players.records, self.connections, 0..) |player, *connection, index| {
            const handle = player.handle orelse continue;
            const flag = @as(u256, 1) << @intCast(index);
            valid |= flag;

            if (connection.generation != handle.generation or connection.life != player.life) {
                reset |= flag;
                connection.* = .{ .generation = handle.generation, .life = player.life };
            }
        }

        _ = self.deps.dropped.nearby(self.deps.players, self.deps.players.config.render_distance);
        const dropped = self.deps.dropped;
        var cursor: usize = 0;
        while (cursor < dropped.residents.len) {
            var ids: [16]entities.Id = undefined;
            var selected_count: usize = 0;
            while (cursor < dropped.residents.len and selected_count < ids.len) : (cursor += 1) {
                const resident_entry = dropped.residents[cursor];
                if (resident_entry.id == 0) continue;
                const view = &self.views[cursor];
                if (view.entity != resident_entry.id) view.* = .{ .entity = resident_entry.id };
                if (!dropped.marked[cursor] and view.spawned == 0) {
                    if (!resident_entry.alive) {
                        try dropped.forget(resident_entry.id);
                        view.* = .{};
                    }
                    continue;
                }
                ids[selected_count] = resident_entry.id;
                selected_count += 1;
            }
            var iterator = dropped.iterate(ids[0..selected_count]);
            defer iterator.deinit();
            while (try iterator.next()) |batch| for (batch) |record| {
                const slot_index = dropped.ids.get(record.id).?;
                const stored_view = &self.views[slot_index];
                var view = stored_view.*;
                const row = .{ .id = record.id, .metadata = try record.read() };
                view.spawned &= valid & ~reset;
                view.dirty &= view.spawned;
                view.collected &= view.spawned;
                view.stacks &= view.spawned;

                if (view.revision != row.metadata.revision) {
                    view.dirty |= view.spawned;
                    view.revision = row.metadata.revision;
                }

                if (view.collection != row.metadata.collection) {
                    view.collection = row.metadata.collection;
                    view.collected = 0;
                }

                const body = if (row.metadata.alive) (try record.body.read() orelse return error.Corrupt) else null;
                var interested: u256 = 0;
                if (body) |value| {
                    const position: minecraft.Position = .{ .x = value.position[0], .y = value.position[1], .z = value.position[2] };
                    var candidates = self.deps.players.nearby(value.world, position, 6);
                    while (candidates != 0) {
                        const index: usize = @intCast(@ctz(candidates));
                        candidates &= candidates - 1;
                        const player = self.deps.players.records[index];
                        if (player.handle == null or player.stage != .ready or value.world != player.world) continue;
                        if (@abs(value.position[0] - player.position.x) > 96 or @abs(value.position[2] - player.position.z) > 96) continue;

                        if (self.deps.streaming.visible(index, value.world, @intFromFloat(@floor(value.position[0] / 16)), @intFromFloat(@floor(value.position[2] / 16))))
                            interested |= @as(u256, 1) << @intCast(index);
                    }
                }

                const held = if (body != null and interested != 0) try self.deps.inventories.get(ItemEntities.slot(body.?)) else inventories.Contents{};

                if (presentation_changed or held.revision != view.inventory_revision) {
                    view.inventory_revision = held.revision;
                    view.stacks |= view.spawned;
                }

                for (service.config.protocols) |*selected| {
                    const protocol = selected.number;
                    for (0..5) |phase| {
                        const wanted = switch (phase) {
                            0 => interested & ~view.spawned,
                            1 => interested & view.spawned & view.stacks,
                            2 => interested & view.spawned & view.dirty & ~view.stacks,
                            3 => if (row.metadata.collected > 0) view.spawned & ~view.collected else @as(u256, 0),
                            4 => view.spawned & ~interested & (if (row.metadata.collected > 0) view.collected else std.math.maxInt(u256)),
                            else => unreachable,
                        };
                        if (wanted == 0) continue;

                        var capacity: usize = 128;
                        if (phase == 1) {
                            const definition = try self.deps.inventories.acquireItem((held.stack orelse return error.Corrupt).item);
                            defer definition.release();
                            capacity = definition.read().?.len + 16 + self.deps.items.components.extra_bytes;
                        }

                        var count: usize = 0;

                        var candidates = wanted;
                        while (candidates != 0) {
                            const index: usize = @intCast(@ctz(candidates));
                            candidates &= candidates - 1;
                            const player = self.deps.players.records[index];
                            const handle = player.handle orelse continue;
                            if (player.protocol != protocol or wanted & (@as(u256, 1) << @intCast(index)) == 0) continue;
                            if (capacity > service.config.page_bytes) {
                                std.log.err("event=item_packet_too_large entity={d} bytes={d} capacity={d}", .{ row.id, capacity, service.config.page_bytes });
                                service.disconnect(handle);
                                continue;
                            }

                            if (!service.canSend(handle, capacity)) continue;
                            self.recipients[count] = handle;
                            count += 1;
                        }

                        if (count == 0) continue;
                        const groups = if (phase == 1 and self.deps.items.components.personalized) count else 1;
                        for (0..groups) |group| {
                            const targets = if (groups == 1) self.recipients[0..count] else self.recipients[group..][0..1];
                            var packet = service.reserve(capacity) catch continue;
                            defer packet.cancel();
                            const entity_id = ItemEntities.networkId(row.id);
                            var length: usize = undefined;

                            if (phase == 0) {
                                length = (try self.deps.packets.writePacket(.{ writeSpawnLegacy, writeSpawnPacked }, protocol, packet.bytes, .{Spawn{
                                    .entity_id = entity_id,
                                    .uuid = body.?.uuid,
                                    .position = .{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                    .velocity = body.?.velocity,
                                }})).len;
                            } else if (phase == 2) {
                                length = (try self.deps.packets.writePacket(writePosition, protocol, packet.bytes, .{
                                    entity_id,
                                    minecraft.Position{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                    minecraft.Position{ .x = body.?.velocity[0], .y = body.?.velocity[1], .z = body.?.velocity[2] },
                                    minecraft.Rotation{ .yaw = 0, .pitch = 0 },
                                    row.metadata.on_ground,
                                })).len;
                            } else if (phase == 4) {
                                length = (try self.deps.packets.writePacket(writeRemove, protocol, packet.bytes, .{entity_id})).len;
                            } else if (phase == 3) {
                                length = (try self.deps.packets.writePacket(writeCollect, protocol, packet.bytes, .{
                                    entity_id, row.metadata.collector, row.metadata.collected,
                                })).len;
                            } else if (phase == 1) {
                                if (held.stack == null) return error.Corrupt;
                                const bytes = self.deps.packets.writePacket(writeItemStack, protocol, packet.bytes, .{
                                    self.deps.items, entity_id, held.stack, self.deps.players.records[targets[0].index].uuid,
                                }) catch |err| switch (err) {
                                    error.EndOfStream, error.UnsupportedItem, error.UnsupportedComponent => {
                                        for (targets) |handle| service.disconnect(handle);
                                        continue;
                                    },
                                    else => return err,
                                };
                                length = bytes.len;
                            } else {
                                unreachable;
                            }

                            var delivered: u256 = 0;

                            for (packet.publishReady(length, targets)) |handle| delivered |= @as(u256, 1) << @intCast(handle.index);

                            switch (phase) {
                                0 => {
                                    view.spawned |= delivered;
                                    view.dirty |= delivered;
                                    view.stacks |= delivered;
                                    view.collected |= delivered;
                                },
                                1 => view.stacks &= ~delivered,
                                2 => view.dirty &= ~delivered,
                                3 => view.collected |= delivered,
                                4 => {
                                    view.spawned &= ~delivered;
                                    view.dirty &= ~delivered;
                                    view.collected &= ~delivered;
                                    view.stacks &= ~delivered;
                                },
                                else => unreachable,
                            }
                        }
                    }
                }

                if (!row.metadata.alive and view.spawned == 0) {
                    stored_view.* = .{};
                    try self.deps.dropped.forget(row.id);
                    continue;
                }

                stored_view.* = view;
            };
        }
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

    pub fn writeItemStack(packet: wire_1_21_5.play.toClient.packet_entity_metadata.Writer, registry: packets.Registry, store: *Items, entity: i32, stack: ?inventories.Stack, recipient: u128) ![]u8 {
        var metadata = try (try packet.entityId(entity)).metadata();
        const done = try packets.nested(.{writeStackMetadata}).write(try metadata.begin(), .{ .registry = registry, .items = store, .stack = stack, .recipient = recipient });
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
