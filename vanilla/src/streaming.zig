const SpatialIndex = @import("player_spatial.zig").Index;
const metrics = @import("metrics");
const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const lightning_rod = @import("lightning_rod");
const chunks = @import("chunks");
const chunk_encoding = @import("chunk_encoding.zig");
const game_data = @import("game_data");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const worlds = @import("worlds");
const players = @import("players.zig");

const lighting = @import("lighting.zig");
const assert = std.debug.assert;

pub const Streaming = struct {
    pub const id = "minecraft:chunk_streaming";

    pub const Configuration = struct {
        biome: i32 = game_data.registry.biomeId("minecraft:plains").?,
    };

    pub const Dependencies = struct {
        metrics: *metrics.Registry,
        players: *players.Players,
        chunks: *chunks.Chunks,
        sessions: *sessions.Service,
        packets: *packets.Packets,
        worlds: *worlds.Worlds,
        lighting: *lighting.Lighting,
    };

    const batch_max = 4;

    pub const Position = struct {
        x: i32,
        z: i32,
    };

    pub const View = struct {
        handle: ?sessions.Handle,
        world: u32,
        protocol: i32,
        life: u32,
        ready: bool,
        loaded: bool,
        center: Position,

        pub fn capture(player: players.Players.Player) View {
            return .{
                .handle = player.handle,
                .world = player.world,
                .protocol = player.protocol,
                .life = player.life,
                .ready = player.stage == .ready,
                .loaded = player.loaded,
                .center = .{ .x = @intFromFloat(@floor(player.position.x / 16)), .z = @intFromFloat(@floor(player.position.z / 16)) },
            };
        }
    };

    const LightChanges = struct {
        bits: []u64,
        words: lightning_rod.system.IndexSet,

        fn init(allocator: std.mem.Allocator, count: usize) !LightChanges {
            const bits = try allocator.alloc(u64, count);
            @memset(bits, 0);
            return .{ .bits = bits, .words = try lightning_rod.system.IndexSet.init(allocator, count) };
        }

        fn mark(self: *LightChanges, slot: struct { word: usize, mask: u64 }) void {
            self.bits[slot.word] |= slot.mask;
            self.words.insert(slot.word);
        }

        fn merge(self: *LightChanges, source: *LightChanges) void {
            for (source.words.values()) |word| {
                self.bits[word] |= source.bits[word];
                self.words.insert(word);
            }
            source.clear();
        }

        fn clear(self: *LightChanges) void {
            for (self.words.values()) |word| self.bits[word] = 0;
            self.words.clear();
        }
    };

    const Published = struct {
        light: LightChanges,
        mutex: std.Io.Mutex = .init,
        views: []View,
        streams: []Stream,
        sent: []u64,
        dirty_words: std.DynamicBitSetUnmanaged,
        changed_views: lightning_rod.system.IndexSet,
        dirty_streams: lightning_rod.system.IndexSet,
        epoch: u64 = 0,
        updated: bool = true,

        pub fn setStream(self: *Published, index: usize, stream: Stream) void {
            if (std.meta.eql(self.streams[index], stream)) return;
            self.streams[index] = stream;
            self.dirty_streams.insert(index);
        }
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

    acquired_chunks: metrics.Counter,
    encoded_bytes: metrics.Counter,
    encoding_duration: metrics.Timer,
    lighting_duration: metrics.Timer,
    lighting_cpu: metrics.Timer,
    publication: metrics.Timer,
    deps: Dependencies,
    io: std.Io,
    native_io: std.Io,
    published: *Published,
    tracked_views: lightning_rod.system.IndexSet,
    views: []View,
    changed_players: lightning_rod.system.IndexSet,
    background_players: lightning_rod.system.IndexSet,
    observers_index: SpatialIndex,
    generation_updates: []chunks.Generation.Update,
    epoch: u64 = 0,
    pending: bool = true,
    config: Configuration,
    streams: []Stream,
    recipients: []sessions.Handle,
    cursors: []usize,
    planned: []usize,
    sent: []u64,
    words_per_player: usize,
    visibility: Visibility,
    dirty_words: std.DynamicBitSetUnmanaged,
    next_player: usize = 0,
    encoding: *chunk_encoding.Workspace,
    light_staged: LightChanges,
    light_pending: LightChanges,
    changed: *std.Io.Event,
    wake_pending: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*Streaming {
        if (deps.chunks.backgroundCapacity() < 24) return error.ChunkCacheTooSmall;

        const self = try allocator.create(Streaming);
        const streams = try allocator.alloc(Stream, deps.players.records.len);

        for (streams) |*stream| stream.* = .{};

        const side: usize = @intCast(deps.players.config.render_distance * 2 + 1);
        const words = (side * side + 63) / 64;
        const sent = try allocator.alloc(u64, streams.len * words);
        @memset(sent, 0);
        const planning = try allocator.alloc(usize, streams.len * 2);
        const published = try allocator.create(Published);
        published.* = .{
            .light = try LightChanges.init(allocator, sent.len),
            .views = try allocator.alloc(View, streams.len),
            .streams = try allocator.alloc(Stream, streams.len),
            .sent = try allocator.alloc(u64, sent.len),
            .dirty_words = try .initEmpty(allocator, sent.len),
            .changed_views = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .dirty_streams = try lightning_rod.system.IndexSet.init(allocator, streams.len),
        };
        @memset(published.streams, .{});
        @memset(published.sent, 0);
        for (deps.players.records, published.views) |player, *view| view.* = View.capture(player);
        for (deps.players.activeSlots()) |index| published.changed_views.insert(index);
        self.* = .{
            .io = io,
            .native_io = io,
            .changed = deps.chunks.ready(),
            .published = published,
            .tracked_views = try lightning_rod.system.IndexSet.init(allocator, deps.players.records.len),
            .views = try allocator.dupe(View, published.views),
            .acquired_chunks = try deps.metrics.counter(.{ .name = "streaming.acquired_chunks", .description = "Chunks acquired for streaming" }),
            .encoded_bytes = try deps.metrics.counter(.{ .name = "streaming.encoded_bytes", .description = "Encoded chunk packet bytes", .unit = .bytes }),
            .lighting_duration = try deps.metrics.timer(.{ .name = "streaming.lighting", .description = "Acquire and light chunk neighborhoods" }),
            .lighting_cpu = try deps.metrics.timer(.{ .name = "streaming.lighting.cpu", .description = "CPU work acquiring and lighting chunk neighborhoods", .clock = .thread_cpu }),
            .encoding_duration = try deps.metrics.timer(.{ .name = "streaming.encoding", .description = "Encode chunk packets" }),
            .publication = try deps.metrics.timer(.{ .name = "streaming.publication", .description = "Publish chunk packet batches" }),
            .encoding = try chunk_encoding.Workspace.init(allocator),
            .light_staged = try LightChanges.init(allocator, sent.len),
            .light_pending = try LightChanges.init(allocator, sent.len),
            .deps = deps,
            .changed_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .background_players = try lightning_rod.system.IndexSet.init(allocator, streams.len),
            .observers_index = try SpatialIndex.init(allocator, streams.len),
            .generation_updates = try allocator.alloc(chunks.Generation.Update, streams.len),
            .config = config,
            .streams = streams,
            .recipients = try allocator.alloc(sessions.Handle, streams.len * batch_max),
            .cursors = planning[0..streams.len],
            .planned = planning[streams.len..],
            .sent = sent,
            .dirty_words = try .initEmpty(allocator, sent.len),
            .words_per_player = words,
            .visibility = .{
                .reset = try lightning_rod.system.IndexSet.init(allocator, streams.len),
                .streams = try allocator.alloc(Stream, streams.len),
                .sent = try allocator.alloc(u64, sent.len),
                .changed = try allocator.alloc(u64, sent.len),
                .changed_words = try lightning_rod.system.IndexSet.init(allocator, sent.len),
                .words_per_player = words,
                .side = @intCast(side),
                .radius = deps.players.config.render_distance,
            },
        };
        for (deps.players.activeSlots()) |index| self.updateAudience(index);
        @memset(self.visibility.streams, .{});
        @memset(self.visibility.sent, 0);
        try deps.chunks.observe(chunks.Observer.init(self, blocksChanged));
        try deps.sessions.subscribeOutput(self.changed);
        try deps.chunks.subscribeReady(self.changed);
        return self;
    }

    pub fn close(self: *Streaming, _: *lightning_rod.Closing) void {
        self.deps.sessions.unsubscribeOutput(self.changed);
        self.deps.chunks.unsubscribeReady(self.changed);
    }

    pub fn endTick(self: *Streaming, completed: bool) void {
        if (!completed) {
            self.light_staged.clear();
            return;
        }
        const published = self.published;
        published.mutex.lockUncancelable(self.native_io);
        defer published.mutex.unlock(self.native_io);
        var changed = self.light_staged.words.count != 0;
        published.light.merge(&self.light_staged);
        for (self.deps.players.activeSlots()) |index| self.tracked_views.insert(index);
        var view_index: usize = 0;
        while (view_index < self.tracked_views.count) {
            const index = self.tracked_views.indices[view_index];
            const player = self.deps.players.records[index];
            const view = &published.views[index];
            if (player.handle == null) self.tracked_views.remove(index) else view_index += 1;
            const current = View.capture(player);
            if (!std.meta.eql(view.*, current)) {
                view.* = current;
                published.changed_views.insert(index);
                changed = true;
            }
        }
        published.updated = published.updated or changed;
        published.epoch = self.deps.sessions.backgroundEpoch() + 1;
        self.wake_pending = changed;
    }

    pub fn publish(self: *Streaming) void {
        if (!self.wake_pending) return;
        self.wake_pending = false;
        self.changed.set(self.io);
    }

    pub fn poll(self: *Streaming, io: std.Io) !bool {
        if (!self.deps.chunks.ownsCurrentThread()) return error.InvalidChunkOwner;
        defer self.deps.sessions.retryBackground(self.epoch);
        const progressed = try self.sendBatch(io, batch_max);
        self.deps.sessions.flush();
        if (progressed) self.changed.set(io);
        return progressed;
    }

    fn sendBatch(self: *Streaming, _: std.Io, maximum_items: usize) !bool {
        const changed = &self.changed_players;
        changed.clear();
        self.published.mutex.lockUncancelable(self.native_io);
        self.epoch = self.published.epoch;
        self.pending = self.pending or self.published.updated;
        self.published.updated = false;
        self.light_pending.merge(&self.published.light);
        if (!self.pending) {
            self.published.mutex.unlock(self.native_io);
            return false;
        }
        for (self.published.changed_views.values()) |index| {
            const previous = &self.views[index];
            const current = self.published.views[index];
            self.background_players.insert(index);
            if (!std.meta.eql(previous.handle, current.handle) or previous.world != current.world or previous.ready != current.ready or !std.meta.eql(previous.center, current.center) or (current.handle != null and !self.observers_index.contains(index))) {
                changed.insert(index);
            }
            previous.* = current;
        }
        self.published.changed_views.clear();
        self.published.mutex.unlock(self.native_io);
        const updates = self.generation_updates;
        var update_count: usize = 0;
        for (changed.values()) |index| {
            const current = self.views[index];
            self.updateAudience(index);
            updates[update_count] = .{ .player = index, .interest = if (current.handle != null and current.ready) .{
                .world = current.world,
                .x = current.center.x,
                .z = current.center.z,
                .radius = @intCast(self.deps.players.config.render_distance + 1),
            } else null };
            update_count += 1;
        }
        self.deps.chunks.generation.updateMany(updates[0..update_count]);
        if (self.epoch != self.deps.sessions.backgroundEpoch() or self.epoch & 1 != 0) return false;
        defer self.publishVisibility();
        const service = self.deps.sessions;
        const radius = self.deps.players.config.render_distance;
        const side: usize = @intCast(2 * radius + 1);
        assert(maximum_items > 0 and maximum_items <= batch_max);
        const batch_limit = @min(maximum_items, self.deps.chunks.backgroundCapacity() / 24);
        var pending: [batch_max]Pending = undefined;
        var count: usize = 0;
        var reserved: usize = 0;
        var released: usize = 0;
        defer for (pending[released..reserved]) |*item| item.packet.cancel();
        const cursors = self.cursors;
        const planned = self.planned;
        for (self.background_players.values()) |index| {
            planned[index] = 0;
            cursors[index] = self.streams[index].cursor;
        }
        var progressed = false;
        self.pending = false;
        var idle: usize = 0;

        for (0..batch_limit * self.background_players.count) |_| {
            if (count == batch_limit or idle == self.background_players.count) break;
            const position = self.next_player % self.background_players.count;
            const index = self.background_players.indices[position];
            self.next_player = (position + 1) % self.background_players.count;
            idle += 1;
            const player = &self.views[index];
            const stream = &self.streams[index];
            const handle = player.handle orelse continue;
            if (!player.ready) continue;

            const center = player.center;

            if (stream.generation != handle.generation or stream.life != player.life) {
                stream.* = .{ .generation = handle.generation, .life = player.life, .center = center, .target = center };
                cursors[index] = 0;
                @memset(self.sent[index * self.words_per_player ..][0..self.words_per_player], 0);
                self.dirty_words.setRangeValue(.{ .start = index * self.words_per_player, .end = (index + 1) * self.words_per_player }, true);
            }

            self.pending = self.pending or stream.setup != .streaming or stream.cursor < side * side or !std.meta.eql(center, stream.center);
            if (!service.canSend(handle, 1)) continue;

            if (stream.setup == .streaming and !std.meta.eql(center, stream.center)) {
                stream.target = center;
                stream.unload_cursor = 0;
                stream.packet_bytes = 0;
                stream.setup = .unloading;
            }

            if (stream.setup == .unloading) {
                var departing = departingPosition(stream.center, stream.target, radius, stream.unload_cursor);
                while (departing) |at| {
                    if (self.hasSent(index, at)) break;
                    stream.unload_cursor += 1;
                    departing = departingPosition(stream.center, stream.target, radius, stream.unload_cursor);
                }

                if (departing == null) {
                    stream.center = stream.target;
                    self.updateAudience(index);
                    stream.cursor = 0;
                    cursors[index] = 0;
                    stream.setup = .center;
                } else {
                    const at = departing.?;
                    var packet = service.reserveBackground(64, self.epoch) catch |err| switch (err) {
                        error.Backpressured => continue,
                        error.Closed => return false,
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
                var packet = service.reserveBackground(64, self.epoch) catch |err| switch (err) {
                    error.Backpressured => continue,
                    error.Closed => return false,
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

            pending[count] = .{ .at = at, .world = player.world, .protocol = player.protocol, .packet = undefined, .owner = index };
            count += 1;
            planned[index] += 1;
            cursors[index] += 1;
            idle = 0;
        }

        if (count == 0) return progressed;
        if (service.backgroundEpoch() != self.epoch) return progressed;
        var reservations: [batch_max]sessions.Service.Packet = undefined;
        count = try service.reserveMany(service.config.page_bytes, reservations[0..count]);
        for (pending[0..count], reservations[0..count]) |*item, packet| {
            item.packet = packet;
            item.packet.epoch = self.epoch;
        }
        reserved = count;
        if (count == 0) return progressed;

        var publications: [batch_max]sessions.Service.Publication = undefined;
        var accepted: [batch_max]usize = undefined;
        var encoded_count: usize = 0;
        var encoded_indices: [batch_max]usize = undefined;
        for (pending[0..count], 0..) |*item, i| {
            var recipients: usize = 0;
            const targets = self.recipients[i * self.views.len ..][0..self.views.len];

            var nearby = self.observers_index.query(.{ .world = item.world, .x = item.at.x, .z = item.at.z }, @intCast(radius));
            while (nearby.next()) |index| {
                const player = &self.views[index];
                const stream = &self.streams[index];
                const handle = player.handle orelse continue;
                if (player.world != item.world or !player.ready or player.protocol != item.protocol or stream.setup != .streaming or stream.generation != handle.generation)
                    continue;
                if (@abs(item.at.x - stream.center.x) > radius or @abs(item.at.z - stream.center.z) > radius or self.hasSent(index, item.at)) continue;
                if (!player.loaded and (@abs(item.at.x - stream.center.x) > 1 or @abs(item.at.z - stream.center.z) > 1)) continue;
                targets[recipients] = handle;
                recipients += 1;
            }

            assert(recipients != 0);
            const dimension = self.deps.worlds.get(item.world).?.dimension;
            // A new solve can outlive this epoch. Publish the encoded packets first.
            if (encoded_count != 0 and !self.deps.lighting.background.current(self.deps.chunks, item.world, item.at.x, item.at.z, dimension)) {
                for (pending[i..count]) |*waiting| waiting.packet.cancel();
                break;
            }
            const lit = try self.prepareLight(item.world, item.at, dimension, item.owner);
            if (!lit or service.backgroundEpoch() != self.epoch) {
                for (pending[i..count]) |*waiting| waiting.packet.cancel();
                self.next_player = self.background_players.positions[item.owner];
                break;
            }
            self.acquired_chunks.add(1);
            const encoded = encode: {
                const encoding = self.encoding_duration.start();
                defer encoding.end();
                break :encode try self.deps.packets.writePacket(chunk_encoding.write, item.protocol, item.packet.bytes, .{ chunk_encoding.Chunk{
                    .x = item.at.x,
                    .z = item.at.z,
                    .sections = self.deps.lighting.background.sections(),
                    .biome = self.config.biome,
                    .minimum_section = dimension.minimumSection(),
                    .workspace = self.encoding,
                    .light = self.deps.lighting.background.data(),
                }, try self.deps.packets.definition(item.protocol) });
            };
            self.encoded_bytes.add(encoded.len);
            self.streams[item.owner].packet_bytes = encoded.len;
            encoded_indices[encoded_count] = i;
            publications[encoded_count] = .{ .packet = &item.packet, .length = encoded.len, .recipients = targets[0..recipients] };
            encoded_count += 1;
            if (service.backgroundEpoch() != self.epoch) {
                for (pending[i + 1 .. count]) |*waiting| waiting.packet.cancel();
                self.next_player = self.background_players.positions[item.owner];
                break;
            }
        }
        {
            const publication = self.publication.start();
            defer publication.end();
            service.publishManyReady(publications[0..encoded_count], accepted[0..encoded_count]);
        }
        released = count;
        for (encoded_indices[0..encoded_count], publications[0..encoded_count], accepted[0..encoded_count]) |item_index, publication, admitted| {
            const item = &pending[item_index];
            for (publication.recipients[0..admitted]) |handle| {
                self.markSent(handle.index, item.at, true);
                const stream = &self.streams[handle.index];
                stream.packet_bytes = publication.length;
                stream.delivered += 1;
                while (stream.cursor < side * side) {
                    const offset = spiral(stream.cursor);
                    if (!self.hasSent(handle.index, .{ .x = stream.center.x + offset.x, .z = stream.center.z + offset.z })) break;
                    stream.cursor += 1;
                }
            }

            progressed = progressed or admitted != 0;
        }

        assert(released == count);
        assert(count <= maximum_items);
        return progressed;
    }

    fn prepareLight(self: *Streaming, world: u32, at: Position, dimension: worlds.Worlds.Dimension, player: usize) !bool {
        const timing = self.lighting_duration.start();
        defer timing.end();
        const cpu = self.lighting_cpu.start();
        defer cpu.end();
        return self.deps.lighting.prepare(world, at.x, at.z, dimension, player);
    }

    fn blocksChanged(self: *Streaming, section: chunks.Section, _: []const chunks.BlockEdit) void {
        const radius = self.deps.players.config.render_distance;
        var audience = self.deps.players.nearby(section.world, .{ .x = @as(f64, @floatFromInt(section.x)) * 16, .y = 0, .z = @as(f64, @floatFromInt(section.z)) * 16 }, radius + 1);
        while (audience.next()) |index| {
            const player = self.deps.players.records[index];
            if (player.handle == null or player.stage != .ready) continue;
            const center = View.capture(player).center;
            for (0..9) |column| {
                const x = std.math.add(i32, section.x, @as(i32, @intCast(column % 3)) - 1) catch continue;
                const z = std.math.add(i32, section.z, @as(i32, @intCast(column / 3)) - 1) catch continue;
                if (@abs(@as(i64, x) - center.x) > radius or @abs(@as(i64, z) - center.z) > radius) continue;
                const slot = self.sentIndex(index, .{ .x = x, .z = z });
                self.light_staged.mark(.{ .word = slot.word, .mask = slot.mask });
            }
        }
    }

    pub fn pollLight(self: *Streaming) !bool {
        if (self.deps.lighting.background.pending != null and self.pending) return false;
        if (self.epoch & 1 != 0 or self.epoch != self.deps.sessions.backgroundEpoch()) return false;
        if (self.light_pending.words.count == 0) return false;
        var output: [batch_max]sessions.Service.Packet = undefined;
        const reserved = self.deps.sessions.reserveMany(@min(lighting.Data.capacity, self.deps.sessions.config.page_bytes), &output) catch |err| switch (err) {
            error.Closed => return false,
            else => return err,
        };
        defer for (output[0..reserved]) |*packet| packet.cancel();
        var publications: [batch_max]sessions.Service.Publication = undefined;
        var admitted: [batch_max]usize = undefined;
        const Plan = struct { world: u32, at: Position, protocol: i32 };
        var plans: [batch_max]Plan = undefined;
        var planned: usize = 0;
        var attempts: usize = 0;
        var cursor: usize = 0;
        while (cursor < self.light_pending.words.count and attempts < reserved) {
            const word = self.light_pending.words.indices[cursor];
            const index = word / self.words_per_player;
            const view = self.views[index];
            const stream = self.streams[index];
            const bits = self.light_pending.bits[word];
            if (bits == 0 or view.handle == null or !view.ready or stream.generation != view.handle.?.generation or stream.life != view.life) {
                self.light_pending.bits[word] = 0;
                self.light_pending.words.remove(word);
                continue;
            }
            const bit = (word % self.words_per_player) * 64 + @ctz(bits);
            const side = self.deps.players.config.render_distance * 2 + 1;
            const radius = self.deps.players.config.render_distance;
            const left = stream.center.x - radius;
            const top = stream.center.z - radius;
            const x = left + @mod(@as(i32, @intCast(bit % @as(usize, @intCast(side)))) - @mod(left, side), side);
            const z = top + @mod(@as(i32, @intCast(bit / @as(usize, @intCast(side)))) - @mod(top, side), side);
            const at: Position = .{ .x = x, .z = z };
            const slot = self.sentIndex(index, at);
            if (bit >= @as(usize, @intCast(side * side)) or !self.visibleView(index, view, view.world, x, z)) {
                self.light_pending.bits[word] &= ~(@as(u64, 1) << @intCast(bit % 64));
                continue;
            }
            var duplicate = false;
            for (plans[0..planned]) |plan| duplicate = duplicate or (plan.world == view.world and plan.protocol == view.protocol and std.meta.eql(plan.at, at));
            if (duplicate) {
                cursor += 1;
                continue;
            }
            attempts += 1;
            var count: usize = 0;
            const recipients = self.recipients[planned * self.views.len ..][0..self.views.len];
            var nearby = self.visibleObservers(self.views, view.world, x, z);
            while (nearby.next()) |recipient| {
                if (self.views[recipient].protocol != view.protocol) continue;
                const other = self.sentIndex(recipient, at);
                if (self.light_pending.bits[other.word] & other.mask == 0) continue;
                recipients[count] = self.views[recipient].handle.?;
                count += 1;
            }
            assert(count != 0 and self.light_pending.bits[slot.word] & slot.mask != 0);
            const dimension = self.deps.worlds.get(view.world).?.dimension;
            if (planned != 0 and !self.deps.lighting.background.current(self.deps.chunks, view.world, x, z, dimension)) break;
            const lit = try self.prepareLight(view.world, at, dimension, index);
            if (self.deps.sessions.backgroundEpoch() != self.epoch) break;
            if (!lit) {
                cursor += 1;
                continue;
            }
            const packet = &output[planned];
            packet.epoch = self.epoch;
            const bytes = try self.deps.packets.writePacket(lighting.writeUpdate, view.protocol, packet.bytes, .{ x, z, self.deps.lighting.background.data() });
            publications[planned] = .{ .packet = packet, .length = bytes.len, .recipients = recipients[0..count] };
            plans[planned] = .{ .world = view.world, .at = at, .protocol = view.protocol };
            planned += 1;
            cursor += 1;
        }
        self.deps.sessions.publishManyReady(publications[0..planned], admitted[0..planned]);
        var progressed = false;
        for (plans[0..planned], publications[0..planned], admitted[0..planned]) |plan, publication, count| {
            for (publication.recipients[0..count]) |handle| {
                const other = self.sentIndex(handle.index, plan.at);
                self.light_pending.bits[other.word] &= ~other.mask;
            }
            progressed = progressed or count != 0;
        }
        self.deps.sessions.flush();
        if (progressed) self.changed.set(self.io);
        return progressed;
    }

    fn publishVisibility(self: *Streaming) void {
        const published = self.published;
        published.mutex.lockUncancelable(self.native_io);
        defer published.mutex.unlock(self.native_io);
        var position: usize = 0;
        while (position < self.background_players.count) {
            const index = self.background_players.indices[position];
            if (self.views[index].handle == null) {
                self.streams[index] = .{};
                @memset(self.sent[index * self.words_per_player ..][0..self.words_per_player], 0);
                self.dirty_words.setRangeValue(.{ .start = index * self.words_per_player, .end = (index + 1) * self.words_per_player }, true);
                self.background_players.remove(index);
            } else position += 1;
            const stream = self.streams[index];
            published.setStream(index, stream);
        }
        var dirty = self.dirty_words.iterator(.{});
        while (dirty.next()) |word| {
            published.sent[word] = self.sent[word];
            published.dirty_words.set(word);
            self.dirty_words.unset(word);
        }
    }

    pub const Visibility = struct {
        reset: lightning_rod.system.IndexSet,
        changed: []u64,
        changed_words: lightning_rod.system.IndexSet,
        streams: []Stream,
        sent: []u64,
        words_per_player: usize,
        side: i32,
        radius: i32,

        fn capture(self: *Visibility, published: *Published, io: std.Io) void {
            published.mutex.lockUncancelable(io);
            defer published.mutex.unlock(io);
            self.reset.clear();
            self.changed_words.clear();
            for (published.dirty_streams.values()) |player| {
                const stream = published.streams[player];
                const destination = &self.streams[player];
                if (stream.generation != destination.generation or stream.life != destination.life or stream.setup != destination.setup or !std.meta.eql(stream.center, destination.center)) self.reset.insert(player);
                destination.* = stream;
            }
            var dirty = published.dirty_words.iterator(.{});
            while (dirty.next()) |word| {
                const changed = self.sent[word] ^ published.sent[word];
                if (changed != 0) {
                    self.changed[word] = changed;
                    self.changed_words.insert(@intCast(word));
                }
                self.sent[word] = published.sent[word];
                published.dirty_words.unset(word);
            }
            published.dirty_streams.clear();
        }

        pub fn viewCenter(self: *const Visibility, player: usize) Position {
            return self.streams[player].center;
        }

        pub fn visible(self: *const Visibility, player: usize, record: *const players.Players.Player, world: u32, x: i32, z: i32) bool {
            const stream = self.streams[player];
            if (record.world != world) return false;

            const handle = record.handle orelse return false;
            const radius: u64 = @intCast(self.radius);
            const slot = sentIndexFor(self.words_per_player, self.side, player, .{ .x = x, .z = z });
            return stream.generation == handle.generation and stream.life == record.life and stream.setup != .terrain and
                @abs(@as(i64, x) - stream.center.x) <= radius and @abs(@as(i64, z) - stream.center.z) <= radius and
                self.sent[slot.word] & slot.mask != 0;
        }
    };

    /// The simulation owns this view until its next snapshot.
    pub fn snapshotVisibility(self: *Streaming) *const Visibility {
        self.visibility.capture(self.published, self.native_io);
        return &self.visibility;
    }

    fn updateAudience(self: *Streaming, index: usize) void {
        const view = self.views[index];
        const stream = self.streams[index];
        const handle = view.handle orelse {
            self.observers_index.update(index, null);
            return;
        };
        const center = if (stream.generation == handle.generation and stream.life == view.life) stream.center else view.center;
        self.observers_index.update(index, .{ .world = view.world, .x = center.x, .z = center.z });
    }

    pub const Observers = struct {
        owner: *const Streaming,
        views: []const View,
        query: SpatialIndex.Query,
        world: u32,
        at: Position,

        pub fn next(self: *Observers) ?usize {
            while (self.query.next()) |index| {
                if (self.owner.visibleView(index, self.views[index], self.world, self.at.x, self.at.z)) return index;
            }
            return null;
        }
    };

    /// Borrows a background snapshot and delivered chunk membership until either changes.
    pub fn visibleObservers(self: *const Streaming, views: []const View, world: u32, x: i32, z: i32) Observers {
        assert(views.len == self.views.len);
        return .{ .owner = self, .views = views, .world = world, .at = .{ .x = x, .z = z }, .query = self.observers_index.query(.{ .world = world, .x = x, .z = z }, self.deps.players.config.render_distance) };
    }

    pub fn visibleView(self: *const Streaming, index: usize, view: View, world: u32, x: i32, z: i32) bool {
        const handle = view.handle orelse return false;
        const stream = self.streams[index];
        const radius: u64 = @intCast(self.deps.players.config.render_distance);
        return view.world == world and stream.generation == handle.generation and stream.life == view.life and
            stream.setup != .terrain and @abs(@as(i64, x) - stream.center.x) <= radius and
            @abs(@as(i64, z) - stream.center.z) <= radius and self.hasSent(index, .{ .x = x, .z = z });
    }

    const SentIndex = struct { word: usize, mask: u64 };

    fn sentIndexFor(words: usize, side: i32, index: usize, at: Position) SentIndex {
        const slot: usize = @intCast(@mod(at.z, side) * side + @mod(at.x, side));
        return .{ .word = index * words + slot / 64, .mask = @as(u64, 1) << @intCast(slot % 64) };
    }

    fn sentIndex(self: *const Streaming, index: usize, at: Position) SentIndex {
        return sentIndexFor(self.words_per_player, self.deps.players.config.render_distance * 2 + 1, index, at);
    }

    fn hasSent(self: *const Streaming, index: usize, at: Position) bool {
        const slot = self.sentIndex(index, at);
        return self.sent[slot.word] & slot.mask != 0;
    }

    fn markSent(self: *Streaming, index: usize, at: Position, value: bool) void {
        const slot = self.sentIndex(index, at);
        self.sent[slot.word] = (self.sent[slot.word] & ~slot.mask) | (slot.mask * @intFromBool(value));
        self.dirty_words.set(slot.word);
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
};

fn departingPosition(center: Streaming.Position, target: Streaming.Position, radius: i32, cursor: usize) ?Streaming.Position {
    assert(radius >= 0 and radius <= 32);
    const side = radius * 2 + 1;
    const low: Streaming.Position = .{ .x = center.x - radius, .z = center.z - radius };
    const high: Streaming.Position = .{ .x = center.x + radius, .z = center.z + radius };
    const overlap_low: Streaming.Position = .{ .x = @max(low.x, target.x - radius), .z = @max(low.z, target.z - radius) };
    const overlap_high: Streaming.Position = .{ .x = @min(high.x, target.x + radius), .z = @min(high.z, target.z + radius) };
    const Rectangle = struct { x: i32, z: i32, width: i32, height: i32 };
    if (overlap_low.x > overlap_high.x or overlap_low.z > overlap_high.z) {
        const width: usize = @intCast(side);
        if (cursor >= width * width) return null;
        return .{ .x = low.x + @as(i32, @intCast(cursor % width)), .z = low.z + @as(i32, @intCast(cursor / width)) };
    }
    const rectangles = [_]Rectangle{
        .{ .x = low.x, .z = low.z, .width = side, .height = overlap_low.z - low.z },
        .{ .x = low.x, .z = overlap_low.z, .width = overlap_low.x - low.x, .height = overlap_high.z - overlap_low.z + 1 },
        .{ .x = overlap_high.x + 1, .z = overlap_low.z, .width = high.x - overlap_high.x, .height = overlap_high.z - overlap_low.z + 1 },
        .{ .x = low.x, .z = overlap_high.z + 1, .width = side, .height = high.z - overlap_high.z },
    };
    var remaining = cursor;
    for (rectangles) |rectangle| {
        const count: usize = @intCast(rectangle.width * rectangle.height);
        if (remaining < count) {
            const width: usize = @intCast(rectangle.width);
            return .{ .x = rectangle.x + @as(i32, @intCast(remaining % width)), .z = rectangle.z + @as(i32, @intCast(remaining / width)) };
        }
        remaining -= count;
    }
    return null;
}

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

test "visibility snapshots remain stable until the simulation captures another publication" {
    var streams = [_]Streaming.Stream{.{ .generation = 1, .life = 4, .setup = .streaming }};
    var sent = [_]u64{1};
    var published: Streaming.Published = .{
        .light = try Streaming.LightChanges.init(std.testing.allocator, 1),
        .views = &.{},
        .streams = &streams,
        .sent = &sent,
        .dirty_words = try .initEmpty(std.testing.allocator, sent.len),
        .changed_views = try lightning_rod.system.IndexSet.init(std.testing.allocator, streams.len),
        .dirty_streams = try lightning_rod.system.IndexSet.init(std.testing.allocator, streams.len),
    };
    defer std.testing.allocator.free(published.light.bits);
    defer published.light.words.deinit(std.testing.allocator);
    defer published.dirty_words.deinit(std.testing.allocator);
    defer published.changed_views.deinit(std.testing.allocator);
    defer published.dirty_streams.deinit(std.testing.allocator);
    published.dirty_streams.insert(0);
    var snapshot_streams: [1]Streaming.Stream = @splat(.{});
    var changed: [1]u64 = undefined;
    var snapshot_sent = [_]u64{0};
    var snapshot: Streaming.Visibility = .{ .reset = try lightning_rod.system.IndexSet.init(std.testing.allocator, snapshot_streams.len), .changed = &changed, .changed_words = try lightning_rod.system.IndexSet.init(std.testing.allocator, sent.len), .streams = &snapshot_streams, .sent = &snapshot_sent, .words_per_player = 1, .side = 3, .radius = 1 };
    defer snapshot.changed_words.deinit(std.testing.allocator);
    defer snapshot.reset.deinit(std.testing.allocator);
    var player: players.Players.Player = .{ .handle = .{ .index = 0, .generation = 1 }, .world = 0, .life = 4 };
    published.dirty_words.set(0);
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(snapshot.visible(0, &player, 0, 0, 0));
    try std.testing.expectEqualSlices(usize, &.{0}, snapshot.reset.values());
    try std.testing.expectEqualSlices(usize, &.{0}, snapshot.changed_words.values());
    snapshot.capture(&published, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), snapshot.reset.count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.changed_words.count);
    sent[0] = 0;
    published.dirty_words.set(0);
    try std.testing.expect(snapshot.visible(0, &player, 0, 0, 0));
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(!snapshot.visible(0, &player, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), snapshot.reset.count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.changed[0]);
    sent[0] = 1;
    streams[0].generation = 2;
    published.dirty_streams.insert(0);
    published.dirty_words.set(0);
    snapshot.capture(&published, std.testing.io);
    try std.testing.expect(!snapshot.visible(0, &player, 0, 0, 0));
    player.handle.?.generation = 2;
    try std.testing.expect(snapshot.visible(0, &player, 0, 0, 0));
    player.life += 1;
    try std.testing.expect(!snapshot.visible(0, &player, 0, 0, 0));
}

test "departing strips match rectangle subtraction for movement and teleports" {
    const center: Streaming.Position = .{ .x = -17, .z = 31 };
    for ([_]i32{ 0, 2, 8, 32 }) |radius| for ([_]i32{ -65, -3, -1, 0, 1, 3, 65 }) |dx| for ([_]i32{ -65, -3, -1, 0, 1, 3, 65 }) |dz| {
        const target: Streaming.Position = .{ .x = center.x + dx, .z = center.z + dz };
        const side: usize = @intCast(radius * 2 + 1);
        var seen: [65 * 65]bool = @splat(false);
        var count: usize = 0;
        while (departingPosition(center, target, radius, count)) |at| : (count += 1) {
            try std.testing.expect(@abs(at.x - center.x) <= radius and @abs(at.z - center.z) <= radius);
            try std.testing.expect(@abs(at.x - target.x) > radius or @abs(at.z - target.z) > radius);
            const x: usize = @intCast(at.x - center.x + radius);
            const z: usize = @intCast(at.z - center.z + radius);
            const index = z * side + x;
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
        var expected: usize = 0;
        for (0..side * side) |index| {
            const x = center.x + @as(i32, @intCast(index % side)) - radius;
            const z = center.z + @as(i32, @intCast(index / side)) - radius;
            const outside = @abs(x - target.x) > radius or @abs(z - target.z) > radius;
            try std.testing.expectEqual(outside, seen[index]);
            expected += @intFromBool(outside);
        }
        try std.testing.expectEqual(expected, count);
        try std.testing.expectEqual(null, departingPosition(center, target, radius, count + 1));
    };
    var count: usize = 0;
    while (departingPosition(center, .{ .x = center.x + 1, .z = center.z }, 32, count) != null) : (count += 1) {}
    try std.testing.expectEqual(@as(usize, 65), count);
}
