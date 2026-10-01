const std = @import("std");
const protocols = @import("protocols");
const wire_1_21_5 = @import("wire_1_21_5");
const metrics = @import("metrics");
const lightning_rod = @import("lightning_rod");
const chunks = @import("chunks");
const minecraft = @import("minecraft_model");
const game_data = @import("game_data");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const worlds = @import("worlds");
const players = @import("players.zig");

const assert = std.debug.assert;

const Trace = metrics.Metrics(enum { acquisition, encoding });

pub const Streaming = struct {
    pub const id = "minecraft:chunk_streaming";

    pub const Configuration = struct {
        biome: i32 = game_data.registry.biomeId("minecraft:plains").?,
        metrics: metrics.Options = .{},
    };

    pub const Dependencies = struct {
        players: *players.Players,
        chunks: *chunks.Chunks,
        work: *lightning_rod.Work,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        worlds: *worlds.Worlds,
    };

    const batch_max = 4;

    pub const Position = struct {
        x: i32,
        z: i32,
    };

    const Stream = struct {
        generation: u32 = 0,
        life: u32 = 0,
        setup: enum { terrain, center, streaming, unloading } = .terrain,
        center: Position = .{ .x = 0, .z = 0 },
        target: Position = .{ .x = 0, .z = 0 },
        cursor: usize = 0,
        unload_cursor: usize = 0,
        delivered: usize = 0,
        packet_bytes: usize = 0,
    };

    const Pending = struct {
        at: Position,
        world: u32,
        protocol: i32,
        packet: sessions.Service.Packet,
        owner: usize,
    };

    deps: Dependencies,
    config: Configuration,
    streams: []Stream,
    recipients: []sessions.Handle,
    cursors: []usize,
    planned: []usize,
    sent: []u64,
    words_per_player: usize,
    next_player: usize = 0,
    metrics: Trace,
    encoded_chunks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Streaming {
        if (deps.chunks.cache.entries.len < 24) return error.ChunkCacheTooSmall;

        const self = try allocator.create(Streaming);
        const streams = try allocator.alloc(Stream, deps.players.records.len);

        for (streams) |*stream| stream.* = .{};

        const side: usize = @intCast(deps.players.config.render_distance * 2 + 1);
        const words = (side * side + 63) / 64;
        const sent = try allocator.alloc(u64, streams.len * words);
        @memset(sent, 0);
        const planning = try allocator.alloc(usize, streams.len * 2);
        self.* = .{
            .deps = deps,
            .config = config,
            .streams = streams,
            .recipients = try allocator.alloc(sessions.Handle, streams.len),
            .cursors = planning[0..streams.len],
            .planned = planning[streams.len..],
            .sent = sent,
            .words_per_player = words,
            .metrics = Trace.init(io, config.metrics),
        };
        try deps.work.register(.{ .context = self, .maximum_items = batch_max, .run = progress });
        return self;
    }

    fn progress(context: *anyopaque, _: std.Io, maximum_items: usize) !lightning_rod.Work.Result {
        const self: *Streaming = @ptrCast(@alignCast(context));
        const service = self.deps.sessions;
        const radius = self.deps.players.config.render_distance;
        const side: usize = @intCast(2 * radius + 1);
        assert(maximum_items > 0 and maximum_items <= batch_max);
        const batch_limit = @min(maximum_items, self.deps.chunks.cache.entries.len / 24);
        var pending: [batch_max]Pending = undefined;
        var count: usize = 0;
        var released: usize = 0;
        defer for (pending[released..count]) |*item| item.packet.cancel();
        const cursors = self.cursors;
        const planned = self.planned;
        @memset(planned, 0);

        for (self.streams, cursors) |stream, *cursor| cursor.* = stream.cursor;
        var progressed = false;
        var pending_work = false;

        for (self.deps.players.records, self.streams) |player, stream| {
            if (player.handle) |handle| pending_work = pending_work or stream.generation != handle.generation or stream.delivered != side * side;
        }

        var idle: usize = 0;

        for (0..batch_limit * self.streams.len) |_| {
            if (count == batch_limit or idle == self.streams.len) break;

            const index = self.next_player;
            self.next_player = (index + 1) % self.streams.len;
            idle += 1;
            const player = &self.deps.players.records[index];
            const stream = &self.streams[index];
            const handle = player.handle orelse continue;
            if (player.stage != .ready) continue;

            const center: Position = .{ .x = @intFromFloat(@floor(player.position.x / 16)), .z = @intFromFloat(@floor(player.position.z / 16)) };

            if (stream.generation != handle.generation or stream.life != player.life) {
                stream.* = .{ .generation = handle.generation, .life = player.life, .center = center, .target = center };
                cursors[index] = 0;
                @memset(self.sent[index * self.words_per_player ..][0..self.words_per_player], 0);
            }

            if (!service.canSend(handle, 1)) continue;

            if (stream.setup == .streaming and !std.meta.eql(center, stream.center)) {
                stream.target = center;
                stream.unload_cursor = 0;
                stream.packet_bytes = 0;
                stream.setup = .unloading;
            }

            if (stream.setup == .unloading) {
                while (stream.unload_cursor < side * side) {
                    const at: Position = .{
                        .x = stream.center.x + @as(i32, @intCast(stream.unload_cursor % side)) - radius,
                        .z = stream.center.z + @as(i32, @intCast(stream.unload_cursor / side)) - radius,
                    };
                    if ((@abs(at.x - stream.target.x) > radius or @abs(at.z - stream.target.z) > radius) and self.hasSent(index, at)) break;
                    stream.unload_cursor += 1;
                }

                if (stream.unload_cursor == side * side) {
                    stream.center = stream.target;
                    stream.cursor = 0;
                    cursors[index] = 0;
                    stream.setup = .center;
                } else {
                    const at: Position = .{
                        .x = stream.center.x + @as(i32, @intCast(stream.unload_cursor % side)) - radius,
                        .z = stream.center.z + @as(i32, @intCast(stream.unload_cursor / side)) - radius,
                    };
                    var packet = service.reserve(64) catch |err| switch (err) {
                        error.Backpressured => continue,
                        else => return err,
                    };
                    defer packet.cancel();
                    const bytes = try self.deps.packets.writePacket(writeUnload, player.protocol, packet.bytes, .{at});
                    packet.publish(bytes.len, &.{handle}) catch |err| switch (err) {
                        error.Backpressured, error.Closed => continue,
                        else => return err,
                    };
                    self.markSent(index, at, false);
                    stream.unload_cursor += 1;
                    stream.delivered -= 1;
                    progressed = true;
                    idle = 0;
                    continue;
                }
            }

            if (stream.setup != .streaming) {
                var packet = service.reserve(64) catch |err| switch (err) {
                    error.Backpressured => continue,
                    else => return err,
                };
                defer packet.cancel();
                const bytes = if (stream.setup == .terrain)
                    try self.deps.packets.writePacket(writeTerrainReady, player.protocol, packet.bytes, .{})
                else
                    try self.deps.packets.writePacket(writeViewCenter, player.protocol, packet.bytes, .{stream.center});
                packet.publish(bytes.len, &.{handle}) catch |err| switch (err) {
                    error.Backpressured, error.Closed => continue,
                    else => return err,
                };
                stream.setup = if (stream.setup == .terrain) .center else .streaming;
                progressed = true;
                idle = 0;
                continue;
            }

            const estimate = if (stream.packet_bytes == 0) service.config.page_bytes else stream.packet_bytes;
            if (planned[index] >= service.packetCapacity(handle, estimate)) continue;

            while (cursors[index] < side * side) {
                const offset = spiral(cursors[index]);
                if (!self.hasSent(index, .{ .x = stream.center.x + offset.x, .z = stream.center.z + offset.z })) break;
                cursors[index] += 1;
            }

            if (cursors[index] == side * side) continue;
            // Let the client render its spawn neighborhood before bulk delivery.
            if (!player.loaded and cursors[index] >= 9) continue;

            const offset = spiral(cursors[index]);
            const at: Position = .{ .x = stream.center.x + offset.x, .z = stream.center.z + offset.z };
            var duplicate = false;

            for (pending[0..count]) |item|
                duplicate = duplicate or (item.world == player.world and item.protocol == player.protocol and std.meta.eql(item.at, at));
            if (duplicate) {
                cursors[index] += 1;
                idle = 0;
                continue;
            }

            const packet = service.reserve(service.config.page_bytes) catch |err| switch (err) {
                error.Backpressured => break,
                else => return err,
            };
            pending[count] = .{ .at = at, .world = player.world, .protocol = player.protocol, .packet = packet, .owner = index };
            count += 1;
            planned[index] += 1;
            cursors[index] += 1;
            idle = 0;
        }

        if (count == 0) return if (progressed) .progressed else if (pending_work) .blocked else .idle;

        var sections: [batch_max * 24]chunks.Section = undefined;
        var leases: [batch_max * 24]chunks.Lease = undefined;
        var offsets: [batch_max + 1]usize = undefined;
        offsets[0] = 0;

        for (pending[0..count], 0..) |item, i| {
            const dimension = self.deps.worlds.get(item.world).?.dimension;
            offsets[i + 1] = offsets[i] + dimension.sectionCount();

            for (sections[offsets[i]..offsets[i + 1]], 0..) |*section, y|
                section.* = .{ .world = item.world, .x = item.at.x, .y = @as(i32, @intCast(y)) + dimension.minimumSection(), .z = item.at.z };
        }

        {
            const acquisition = self.metrics.begin(.acquisition);
            defer acquisition.end();
            try self.deps.chunks.acquireMany(sections[0..offsets[count]], leases[0..offsets[count]]);
        }
        defer for (leases[0..offsets[count]]) |lease| lease.release();

        for (pending[0..count], 0..) |*item, i| {
            var recipients: usize = 0;

            for (self.deps.players.records, self.streams, 0..) |*player, *stream, index| {
                const handle = player.handle orelse continue;
                if (player.world != item.world or player.stage != .ready or player.protocol != item.protocol or stream.setup != .streaming or stream.generation != handle.generation)
                    continue;
                if (@abs(item.at.x - stream.center.x) > radius or @abs(item.at.z - stream.center.z) > radius or self.hasSent(index, item.at)) continue;
                if (!player.loaded and (@abs(item.at.x - stream.center.x) > 1 or @abs(item.at.z - stream.center.z) > 1)) continue;
                self.recipients[recipients] = handle;
                recipients += 1;
            }

            assert(recipients != 0);
            const bytes = blk: {
                var encoding = self.metrics.begin(.encoding);
                defer encoding.end();
                const dimension = self.deps.worlds.get(item.world).?.dimension;
                const bytes = try self.deps.packets.writePacket(writeChunk, item.protocol, item.packet.bytes, .{minecraft.Chunk{
                    .x = item.at.x,
                    .z = item.at.z,
                    .sections = leases[offsets[i]..offsets[i + 1]],
                    .biome = self.config.biome,
                    .minimum_section = dimension.minimumSection(),
                    .skylight = dimension.skylight,
                }});
                encoding.add(.bytes, bytes.len);
                encoding.add(.records, 1);
                break :blk bytes;
            };
            self.encoded_chunks += 1;
            self.streams[item.owner].packet_bytes = bytes.len;
            const accepted = item.packet.publishReady(bytes.len, self.recipients[0..recipients]);
            assert(item.packet.reservation == null);
            released += 1;

            for (accepted) |handle| {
                self.markSent(handle.index, item.at, true);
                const stream = &self.streams[handle.index];
                stream.packet_bytes = bytes.len;
                stream.delivered += 1;

                if (stream.delivered == side * side)
                    std.log.info("event=chunk_stream_complete player={d} chunks={d} encoded={d} read_ns={d} encode_ns={d}", .{ handle.index, side * side, self.encoded_chunks, self.metrics.get(.acquisition).total_ns, self.metrics.get(.encoding).total_ns });

                if (stream.delivered == side * side) self.metrics.log("chunk_streaming");

                if (stream.delivered == side * side) self.deps.chunks.cache.metrics.log("chunk_cache");
            }

            progressed = progressed or accepted.len != 0;
        }

        for (self.streams, 0..) |*stream, index| {
            while (stream.cursor < side * side) {
                const offset = spiral(stream.cursor);
                if (!self.hasSent(index, .{ .x = stream.center.x + offset.x, .z = stream.center.z + offset.z })) break;
                stream.cursor += 1;
            }
        }

        assert(released == count);
        assert(count <= maximum_items);
        return if (progressed) .progressed else if (pending_work) .blocked else .idle;
    }

    pub fn visible(self: *const Streaming, player: usize, world: u32, x: i32, z: i32) bool {
        const stream = self.streams[player];
        const record = self.deps.players.records[player];
        if (record.world != world) return false;

        const handle = record.handle orelse return false;
        const radius: u64 = @intCast(self.deps.players.config.render_distance);
        return stream.generation == handle.generation and stream.life == record.life and stream.setup != .terrain and @abs(@as(i64, x) - stream.center.x) <= radius and @abs(@as(i64, z) - stream.center.z) <= radius and self.hasSent(player, .{ .x = x, .z = z });
    }

    pub fn viewCenter(self: *const Streaming, player: usize) Position {
        return self.streams[player].center;
    }

    fn sentIndex(self: *const Streaming, index: usize, at: Position) struct {
        word: usize,
        mask: u64,
    } {
        const side = self.deps.players.config.render_distance * 2 + 1;
        const slot: usize = @intCast(@mod(at.z, side) * side + @mod(at.x, side));
        return .{ .word = index * self.words_per_player + slot / 64, .mask = @as(u64, 1) << @intCast(slot % 64) };
    }

    fn hasSent(self: *const Streaming, index: usize, at: Position) bool {
        const slot = self.sentIndex(index, at);
        return self.sent[slot.word] & slot.mask != 0;
    }

    fn markSent(self: *Streaming, index: usize, at: Position, value: bool) void {
        const slot = self.sentIndex(index, at);
        self.sent[slot.word] = (self.sent[slot.word] & ~slot.mask) | (slot.mask * @intFromBool(value));
    }

    fn writeUnload(packet: wire_1_21_5.play.toClient.packet_unload_chunk.Writer, at: Position) ![]u8 {
        return (try (try packet.chunkZ(at.z)).chunkX(at.x)).finish();
    }

    fn writeTerrainReady(packet: wire_1_21_5.play.toClient.packet_game_state_change.Writer) ![]u8 {
        return (try (try packet.reason(13)).gameMode(0)).finish();
    }

    fn writeViewCenter(packet: wire_1_21_5.play.toClient.packet_update_view_position.Writer, at: Position) ![]u8 {
        return (try (try packet.chunkX(at.x)).chunkZ(at.z)).finish();
    }

    fn writeChunk(packet: wire_1_21_5.play.toClient.packet_map_chunk.Writer, chunk: minecraft.Chunk) ![]u8 {
        inline for (protocols.implementations) |Version| {
            if (packet.protocolNumber() == Version.protocol_number)
                return Version.writeChunk(.{ ._cursor = packet._cursor }, chunk);
        }
        return error.UnsupportedProtocol;
    }
};

fn spiral(index: usize) struct {
    x: i32,
    z: i32,
} {
    if (index == 0) return .{ .x = 0, .z = 0 };

    const ring: i32 = @intCast((std.math.sqrt(index) + 1) / 2);
    const side = ring * 2;
    const start: usize = @intCast((side - 1) * (side - 1));
    const offset: i32 = @intCast(index - start);
    return switch (@divTrunc(offset, side)) {
        0 => .{ .x = ring, .z = -ring + 1 + offset },
        1 => .{ .x = ring - 1 - (offset - side), .z = ring },
        2 => .{ .x = -ring, .z = ring - 1 - (offset - 2 * side) },
        3 => .{ .x = -ring + 1 + (offset - 3 * side), .z = -ring },
        else => unreachable,
    };
}
