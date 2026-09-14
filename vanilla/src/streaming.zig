const std = @import("std");
const metrics = @import("metrics");
const rod = @import("lightning_rod");
const chunks = @import("chunks");
const protocols = @import("protocols");
const sessions = @import("sessions");
const players = @import("players.zig");

const assert = std.debug.assert;
const Client = protocols.wire.play.toClient;

const Trace = metrics.Metrics(enum { acquisition, encoding });

pub const Streaming = struct {
    pub const id = "minecraft:chunk_streaming";

    pub const Configuration = struct {
        biome: i32 = protocols.registry.biomeId("minecraft:plains").?,
        metrics: metrics.Options = .{},
    };

    pub const Dependencies = struct {
        players: *players.Players,
        chunks: *chunks.Chunks,
        work: *rod.Work,
    };

    const batch_max = 8;

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

    fn progress(context: *anyopaque, _: std.Io, maximum_items: usize) !rod.Work.Result {
        const self: *Streaming = @ptrCast(@alignCast(context));
        const service = self.deps.players.deps.sessions;
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
                    const bytes = (try (try (try Client.write(packet.bytes).unload_chunk()).chunkZ(at.z)).chunkX(at.x)).finish();
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
                    (try (try (try Client.write(packet.bytes).game_state_change()).reason(13)).gameMode(0)).finish()
                else
                    (try (try (try Client.write(packet.bytes).update_view_position()).chunkX(stream.center.x)).chunkZ(stream.center.z)).finish();
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
            const dimension = self.deps.players.deps.worlds.get(item.world).?.dimension;
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
                const dimension = self.deps.players.deps.worlds.get(item.world).?.dimension;
                const bytes = try encode(item.packet.bytes, item.at.x, item.at.z, leases[offsets[i]..offsets[i + 1]], self.config.biome, dimension.minimumSection(), dimension == .overworld);
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

fn encode(output: []u8, x: i32, z: i32, sections: []const chunks.Lease, biome: i32, minimum_section: i32, skylight: bool) ![]u8 {
    var writer: std.Io.Writer = .fixed(output);
    try varint(&writer, Client.packetId(.map_chunk));
    try writer.writeInt(i32, x, .big);
    try writer.writeInt(i32, z, .big);
    const minimum_y: i16 = @intCast(minimum_section * 16);
    var heights: [256]i16 = @splat(minimum_y - 1);
    var view_storage: [24]chunks.View = undefined;
    const views = view_storage[0..sections.len];

    for (sections, views) |section, *view| view.* = section.view();

    for (views, 0..) |section, s| {
        if (section == .uniform) {
            if (section.uniform != 0) @memset(&heights, @as(i16, @intCast(s * 16 + 15)) + minimum_y);
            continue;
        }

        for (0..4096) |i| if (section.get(@intCast(i)) != 0) {
            heights[i % 256] = @as(i16, @intCast(s * 16 + i / 256)) + minimum_y;
        };
    }

    try varint(&writer, 2);

    for ([_]i32{ 1, 4 }) |kind| {
        try varint(&writer, kind);
        try varint(&writer, 37);

        for (0..37) |word| {
            var value: u64 = 0;

            for (0..7) |i| {
                const column = word * 7 + i;

                if (column < heights.len) value |= @as(u64, @intCast(heights[column] - minimum_y + 1)) << @intCast(i * 9);
            }

            try writer.writeInt(u64, value, .big);
        }
    }

    const length_offset = writer.end;
    try writer.splatByteAll(0, 3);
    var palette_indices: [1 << protocols.registry.block_state_bits]u16 = @splat(std.math.maxInt(u16));
    var palette: [256]u16 = undefined;

    for (views) |section| {
        const first = section.get(0);
        if (first >= palette_indices.len) return error.InvalidBlockState;

        var count: u16 = 0;
        var palette_len: usize = 0;
        var direct = false;

        if (section == .uniform) {
            count = if (first != 0) 4096 else 0;
            palette[0] = first;
            palette_len = 1;
        } else {
            for (0..4096) |i| {
                const state = section.get(@intCast(i));
                if (state >= palette_indices.len) return error.InvalidBlockState;
                count += @intFromBool(state != 0);
                if (direct or palette_indices[state] != std.math.maxInt(u16)) continue;
                if (palette_len == palette.len) {
                    direct = true;
                    continue;
                }

                palette_indices[state] = @intCast(palette_len);
                palette[palette_len] = state;
                palette_len += 1;
            }
        }

        try writer.writeInt(u16, count, .big);

        if (palette_len == 1 and !direct) {
            try writer.writeByte(0);
            try varint(&writer, first);
        } else {
            const bits: u8 = if (direct) protocols.registry.block_state_bits else @intCast(@max(4, std.math.log2_int_ceil(usize, palette_len)));
            try writer.writeByte(bits);

            if (!direct) {
                try varint(&writer, @intCast(palette_len));

                for (palette[0..palette_len]) |state| try varint(&writer, state);
            }

            const per_word: usize = 64 / bits;

            for (0..(4096 + per_word - 1) / per_word) |word| {
                var value: u64 = 0;

                for (0..per_word) |i| {
                    const index = word * per_word + i;

                    if (index < 4096) {
                        const state = section.get(@intCast(index));
                        const encoded = if (direct) state else palette_indices[state];
                        assert(direct or encoded < palette_len);
                        value |= @as(u64, encoded) << @intCast(i * bits);
                    }
                }

                try writer.writeInt(u64, value, .big);
            }
        }

        for (palette[0..palette_len]) |state| palette_indices[state] = std.math.maxInt(u16);
        try writer.writeByte(0);
        try varint(&writer, biome);
    }

    const length: u32 = @intCast(writer.end - length_offset - 3);
    output[length_offset] = @as(u8, @truncate(length & 127)) | 128;
    output[length_offset + 1] = @as(u8, @truncate((length >> 7) & 127)) | 128;
    output[length_offset + 2] = @intCast(length >> 14);
    try varint(&writer, 0);
    var sky_mask: u32 = 0;
    const minimum = std.mem.min(i16, &heights);
    const maximum = std.mem.max(i16, &heights);
    const light_sections = sections.len + 2;
    const light_mask = (@as(u64, 1) << @intCast(light_sections)) - 1;

    for (0..light_sections) |section| if (skylight and (@as(i32, @intCast(section)) + minimum_section - 1) * 16 + 15 > minimum) {
        sky_mask |= @as(u32, 1) << @intCast(section);
    };

    try varint(&writer, 1);
    try writer.writeInt(u64, sky_mask, .big);
    try varint(&writer, 0);
    try varint(&writer, 1);
    try writer.writeInt(u64, (~@as(u64, sky_mask)) & light_mask, .big);
    try varint(&writer, 1);
    try writer.writeInt(u64, light_mask, .big);
    try varint(&writer, @popCount(sky_mask));

    for (0..light_sections) |section| {
        if (sky_mask & (@as(u32, 1) << @intCast(section)) == 0) continue;
        try varint(&writer, 2048);
        const light = try writer.writableSlice(2048);
        if ((@as(i32, @intCast(section)) + minimum_section - 1) * 16 > maximum) {
            @memset(light, 255);
            continue;
        }

        for (light, 0..) |*byte, i| {
            const y = (@as(i32, @intCast(section)) + minimum_section - 1) * 16 + @as(i32, @intCast(i / 128));
            byte.* = @as(u8, if (y > heights[(i * 2) % 256]) 15 else 0) | @as(u8, if (y > heights[(i * 2 + 1) % 256]) 240 else 0);
        }
    }

    try varint(&writer, 0);
    return output[0..writer.end];
}

fn varint(writer: *std.Io.Writer, value: i32) !void {
    var number: u32 = @bitCast(value);

    while (number >= 128) : (number >>= 7) try writer.writeByte(@as(u8, @truncate(number & 127)) | 128);
    try writer.writeByte(@intCast(number));
}
