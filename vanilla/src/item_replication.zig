const std = @import("std");
const inventories = @import("inventories");
const rod = @import("lightning_rod");
const records = @import("records");
const sessions = @import("sessions");
const minecraft = @import("minecraft");
const protocols = @import("protocols");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const ItemTick = @import("item_tick.zig").ItemTick;
const Players = @import("players.zig").Players;
const Streaming = @import("streaming.zig").Streaming;

const assert = std.debug.assert;

pub const ItemReplication = struct {
    pub const id = "minecraft:item_replication";

    pub const Configuration = struct { cache_records: usize = 256 };

    pub const Dependencies = struct {
        dropped: *ItemEntities,
        item_tick: *ItemTick,
        players: *Players,
        streaming: *Streaming,
        storage: rod.storage.Namespace,
    };

    const View = struct {
        epoch: u64 = 0,
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
    cache: records.Cache,
    epoch: u64,
    connections: []Connection,
    recipients: []sessions.Handle,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*ItemReplication {
        var bytes: [8]u8 = @splat(0);
        if (try deps.storage.get(&.{0}, &bytes)) |length| if (length != 8) return error.Corrupt;

        const previous = std.mem.readInt(u64, &bytes, .little);
        if (previous == std.math.maxInt(u64)) return error.IdExhausted;
        std.mem.writeInt(u64, &bytes, previous + 1, .little);
        try deps.storage.put(&.{0}, &bytes);
        const self = try allocator.create(ItemReplication);
        const connections = try allocator.alloc(Connection, deps.players.records.len);
        @memset(connections, .{});
        self.* = .{
            .deps = deps,
            .epoch = previous + 1,
            .connections = connections,
            .recipients = try allocator.alloc(sessions.Handle, connections.len),
            .cache = try records.Cache.init(allocator, io, deps.storage, .{ .slots = config.cache_records, .key_bytes = 9, .value_bytes = 160 }),
        };
        return self;
    }

    pub fn tick(self: *ItemReplication) !void {
        const service = self.deps.players.deps.sessions;
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

        var cursor: ItemEntities.Cursor = .{};

        while (cursor.more) for (try self.deps.dropped.scan(&cursor)) |row| {
            var key: [9]u8 = undefined;
            key[0] = 1;
            std.mem.writeInt(u64, key[1..9], row.id, .big);
            const lease = try self.cache.acquire(&key);
            defer lease.release();
            var view: View = .{ .epoch = self.epoch };
            var initialized = false;
            if (lease.read()) |bytes| {
                if (bytes.len != 160) return error.Corrupt;
                initialized = std.mem.readInt(u64, bytes[0..8], .little) == self.epoch;

                if (initialized) view = .{
                    .epoch = self.epoch,
                    .revision = std.mem.readInt(u64, bytes[8..16], .little),
                    .collection = std.mem.readInt(u64, bytes[16..24], .little),
                    .spawned = std.mem.readInt(u256, bytes[24..56], .little),
                    .dirty = std.mem.readInt(u256, bytes[56..88], .little),
                    .collected = std.mem.readInt(u256, bytes[88..120], .little),
                    .inventory_revision = std.mem.readInt(u64, bytes[120..128], .little),
                    .stacks = std.mem.readInt(u256, bytes[128..160], .little),
                };
            }

            const previous = view;
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

            const body = if (row.metadata.alive) (try self.deps.dropped.deps.entities.get(row.id) orelse return error.Corrupt) else null;
            var interested: u256 = 0;
            if (body) |value| for (self.deps.players.records, 0..) |player, index| {
                if (player.handle == null or player.stage != .ready or value.world != player.world) continue;
                if (@abs(value.position[0] - player.position.x) > 96 or @abs(value.position[2] - player.position.z) > 96) continue;

                if (self.deps.streaming.visible(index, value.world, @intFromFloat(@floor(value.position[0] / 16)), @intFromFloat(@floor(value.position[2] / 16))))
                    interested |= @as(u256, 1) << @intCast(index);
            };

            const held = if (body != null and interested != 0) try self.deps.dropped.deps.inventories.get(ItemEntities.slot(body.?)) else inventories.Contents{};

            if (held.revision != view.inventory_revision) {
                view.inventory_revision = held.revision;
                view.stacks |= view.spawned;
            }

            for ([_]i32{ 771, 772 }) |protocol| {
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
                        const definition = try self.deps.dropped.deps.inventories.acquireItem((held.stack orelse return error.Corrupt).item);
                        defer definition.release();
                        capacity = definition.read().?.len + 16;
                    }

                    var count: usize = 0;

                    for (self.deps.players.records, 0..) |player, index| {
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

                    var packet = service.reserve(capacity) catch continue;
                    defer packet.cancel();
                    const entity_id = ItemEntities.networkId(row.id);
                    var length: usize = undefined;

                    if (phase == 1) {
                        var rest = try protocols.support.write_varint(packet.bytes, protocols.wire.play.toClient.packetId(.entity_metadata));
                        rest = try protocols.support.write_varint(rest, entity_id);
                        rest[0..2].* = .{ 8, 7 };
                        rest = rest[2..];
                        if (held.stack == null) return error.Corrupt;
                        rest = try self.deps.dropped.deps.items.writeStack(protocol, rest, held.stack);
                        if (rest.len == 0) return error.PacketTooLarge;
                        rest[0] = 255;
                        length = packet.bytes.len - rest.len + 1;
                    } else {
                        const output: minecraft.Output = switch (phase) {
                            0 => .{ .spawn = .{
                                .entity_id = entity_id,
                                .uuid = body.?.uuid,
                                .entity_type = @intCast(body.?.kind),
                                .position = .{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                .pitch = 0,
                                .yaw = 0,
                                .head_yaw = 0,
                                .data = 0,
                                .velocity_x = velocity(body.?.velocity[0]),
                                .velocity_y = velocity(body.?.velocity[1]),
                                .velocity_z = velocity(body.?.velocity[2]),
                            } },
                            2 => .{ .entity_teleport = .{
                                .entity_id = entity_id,
                                .position = .{ .x = body.?.position[0], .y = body.?.position[1], .z = body.?.position[2] },
                                .velocity = .{ .x = body.?.velocity[0], .y = body.?.velocity[1], .z = body.?.velocity[2] },
                                .rotation = .{ .yaw = 0, .pitch = 0 },
                                .on_ground = row.metadata.on_ground,
                            } },
                            3 => .{ .collect = .{ .item = entity_id, .player = row.metadata.collector, .count = row.metadata.collected } },
                            4 => .{ .entity_remove = entity_id },
                            else => unreachable,
                        };
                        length = (try minecraft.Generated(protocols.wire).write(protocol, packet.bytes, output)).len;
                    }

                    var delivered: u256 = 0;

                    for (packet.publishReady(length, self.recipients[0..count])) |handle| delivered |= @as(u256, 1) << @intCast(handle.index);

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

            if (!row.metadata.alive and view.spawned == 0) {
                lease.remove();
                try self.deps.dropped.forget(row.id);
                continue;
            }

            if (initialized and std.meta.eql(previous, view)) continue;

            const bytes = lease.edit();
            std.mem.writeInt(u64, bytes[0..8], view.epoch, .little);
            std.mem.writeInt(u64, bytes[8..16], view.revision, .little);
            std.mem.writeInt(u64, bytes[16..24], view.collection, .little);
            std.mem.writeInt(u256, bytes[24..56], view.spawned, .little);
            std.mem.writeInt(u256, bytes[56..88], view.dirty, .little);
            std.mem.writeInt(u256, bytes[88..120], view.collected, .little);
            std.mem.writeInt(u64, bytes[120..128], view.inventory_revision, .little);
            std.mem.writeInt(u256, bytes[128..160], view.stacks, .little);
            lease.commit(160);
        };
    }

    pub fn checkpoint(self: *ItemReplication, _: rod.storage.Namespace) !void {
        try self.cache.flush();
    }
};

fn velocity(value: f64) i16 {
    assert(std.math.isFinite(value));
    return @intFromFloat(std.math.clamp(value, -3.9, 3.9) * 8000);
}
