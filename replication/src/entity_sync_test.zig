//! The smallest kind on the shared ServerEntity, and the template for a new one: a marker that
//! moves, turns and changes two data entries. Clients are modelled from the packets they get, and
//! every tick each one's view of every marker is held to what tracking and the sync say it has.

const std = @import("std");
const entities = @import("entities");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocols = @import("minecraft_packets").protocols;
const minecraft = @import("minecraft_model");
const Players = @import("players").players.Players;
const Tracking = @import("tracking.zig").Tracking;
const entity_sync = @import("entity_sync.zig");

const Client = protocols.implementations[0].Protocol.play.toClient;

/// A kind's whole replication: what it synchronizes, how each entry is written, and the sync.
/// Where one is and what it is the fixture says, as `Fixture.body` and `Fixture.identity`.
const Marker = struct {
    pub const Data = struct { flags: i8 = 0, count: i32 = 0 };

    fn writeData(_: *Fixture, entries: *entity_sync.Entries, data: Data, changes: Sync.DataChanges) !void {
        if (changes.contains(.flags)) try entries.putByte(0, data.flags);
        if (changes.contains(.count)) try entries.putInt(8, data.count);
    }

    const Sync = entity_sync.EntitySync(Data, Fixture);
    const kind = 1;
    const update_interval = 3;
};

/// What a client knows of one marker, from the packets it got.
const Seen = struct { known: bool = false, position: [3]f64 = .{ 0, 0, 0 }, yaw: i8 = 0, pitch: i8 = 0 };

const Fixture = struct {
    allocator: std.mem.Allocator,
    service: *sessions.Service,
    entities: *entities.Entities,
    records: []Players.Player,
    players: Players,
    tracking: *Tracking,
    sync: Marker.Sync,
    random: std.Random.DefaultPrng,
    live: std.ArrayList(u64) = .empty,
    next_id: u64 = 1,
    /// By client and slot, what the client was told.
    seen: []Seen,
    yaws: []f32,
    data: []Marker.Data,
    slots: usize,

    fn init(self: *Fixture, allocator: std.mem.Allocator, count: usize, seed: u64) !void {
        const selected = comptime definitions: {
            var result: [protocols.implementations.len]sessions.Protocol = undefined;
            for (protocols.implementations, 0..) |Version, i| result[i] = .{ .number = Version.protocol_number };
            break :definitions result;
        };
        const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = count, .pages = 256 * count, .page_bytes = 4096, .credit_bytes = 4 * 1024 * 1024, .protocols = &selected });
        const records = try allocator.alloc(Players.Player, count);
        for (records, 0..) |*player, index| {
            player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .protocol = selected[0].number, .name = @splat('a'), .name_len = 1, .stage = .ready, .loaded = true, .on_ground = true, .position = .{ .x = 0, .y = 64, .z = 0 } };
            service.occupied[index].store(true, .release);
        }
        const owned = try entities.Entities.allocate(allocator, std.testing.io, .{ .memory = 1024 * entities.pool.page_bytes }, undefined);
        const packet_api = try packets.Packets.init(allocator, .{ .sessions = service });
        self.* = .{
            .allocator = allocator,
            .service = service,
            .entities = owned,
            .records = records,
            .players = .{ .deps = .{ .entities = owned, .sessions = service, .packets = packet_api, .input = undefined, .storage = undefined, .worlds = undefined, .record_workspaces = undefined }, .config = .{ .maximum = count, .render_distance = 6 }, .spawn_world = 0, .records = records, .dig_handlers = &.{} },
            .tracking = undefined,
            .sync = undefined,
            .random = .init(seed),
            .seen = undefined,
            .yaws = undefined,
            .data = undefined,
            .slots = owned.directory.capacity(),
        };
        self.players.setRules(.init(Fixture, self, gameMode, spawnWorld, spawnPoint));
        self.players.entities = owned;
        try self.players.initIndexes(allocator);
        try self.players.rebuildIndexes();
        self.tracking = try Tracking.init(allocator, .{}, .{ .entities = owned, .players = &self.players });
        _ = try self.tracking.register(.{ .kinds = .of(&.{Marker.kind}), .range = 64 });
        self.sync = try .init(allocator, .{}, .{ .players = &self.players, .sessions = service, .packets = packet_api, .tracking = self.tracking, .pool = &owned.pool }, .{ .kind = self, .write_data = Marker.writeData, .body = body, .identity = identity, .update_interval = Marker.update_interval, .track_deltas = false });
        self.seen = try allocator.alloc(Seen, count * self.slots);
        @memset(self.seen, .{});
        self.yaws = try allocator.alloc(f32, self.slots);
        self.data = try allocator.alloc(Marker.Data, self.slots);
        for (0..count) |index| self.open(index, true);
    }

    fn gameMode(_: *Fixture, _: usize) minecraft.GameMode {
        return .survival;
    }

    fn spawnWorld(_: *Fixture) u32 {
        return 0;
    }

    fn spawnPoint(_: *Fixture, _: *const Players.Player) anyerror!?Players.Rules.Spawn {
        return null;
    }

    fn open(self: *Fixture, index: usize, room: bool) void {
        const generation: u64 = self.records[index].handle.?.generation;
        self.service.credit[index].store(generation << 32 | sessions.Service.active | (if (room) self.service.config.credit_bytes else 0), .release);
    }

    fn point(self: *Fixture) [3]f64 {
        const random = self.random.random();
        return .{ (random.float(f64) - 0.5) * 200, 64, (random.float(f64) - 0.5) * 200 };
    }

    /// Markers come and go, walk, jump now and then, turn and change their data.
    fn stir(self: *Fixture) !void {
        const random = self.random.random();
        for (0..random.uintLessThan(usize, 3)) |_| {
            const id = self.next_id;
            self.next_id += 1;
            const slot = try self.entities.enter(id, Marker.kind);
            try self.entities.places.insert(id, 0, self.point(), .{ .kind = Marker.kind, .half_width = 0.25, .height = 0.5 });
            self.yaws[slot] = 0;
            self.data[slot] = .{};
            try self.live.append(self.allocator, id);
        }
        if (self.live.items.len > 0 and random.uintLessThan(u8, 3) == 0) {
            const id = self.live.swapRemove(random.uintLessThan(usize, self.live.items.len));
            const slot = self.entities.directory.slotOf(id).?;
            self.entities.places.remove(id);
            self.entities.leave(slot);
        }
        for (self.live.items) |id| {
            const slot = self.entities.directory.slotOf(id).?;
            const at = self.entities.places.space.get(id).?.position;
            const next: [3]f64 = if (random.uintLessThan(u8, 60) == 0) self.point() else .{ at[0] + (random.float(f64) - 0.5) * 0.6, at[1], at[2] + (random.float(f64) - 0.5) * 0.6 };
            if (random.boolean()) try self.entities.places.moveById(id, 0, next);
            if (random.uintLessThan(u8, 4) == 0) self.yaws[slot] += (random.float(f32) - 0.5) * 40;
            if (random.uintLessThan(u8, 10) == 0) self.data[slot].flags ^= 1;
            if (random.uintLessThan(u8, 10) == 0) self.data[slot].count += 1;
        }
    }

    /// One tick: tracking, then each marker's ServerEntity in id order, then the packets read.
    fn step(self: *Fixture) !void {
        try self.players.rebuildIndexes();
        try self.tracking.tick();
        try self.sync.begin();
        var changes = self.tracking.changesOf(0);
        while (changes.next()) |change| if (change.gone) try self.sync.gone(change.slot);
        std.mem.sort(u64, self.live.items, {}, std.sort.asc(u64));
        for (self.live.items) |id| {
            const slot = self.entities.directory.slotOf(id).?;
            try self.sync.update(slot, .{ .id = id, .data = self.data[slot], .changed = self.tracking.changed(slot) != null });
        }
        try self.sync.finish();
        try self.read();
    }

    /// What a marker is, as the sync asks to spawn it.
    fn identity(self: *Fixture, slot: u32) Marker.Sync.Identity {
        return .{ .uuid = self.entities.directory.entry(slot).id, .entity_type = 0 };
    }

    /// Where a marker is, as the sync asks when something of it goes.
    fn body(self: *Fixture, slot: u32) Marker.Sync.Body {
        const entry = self.entities.directory.entry(slot);
        return .{ .position = self.entities.places.space.get(entry.id).?.position, .velocity = .{ 0, 0, 0 }, .yaw = self.yaws[slot], .pitch = 0, .on_ground = true };
    }

    /// The packets clients got, into what each knows.
    fn read(self: *Fixture) !void {
        while (self.service.output.takeReady()) |packet| {
            defer {
                std.debug.assert(self.service.output.releaseReady(packet.page, packet.generation));
                _ = self.service.preparing.fetchSub(1, .release);
            }
            const header = try Client.readHeader(packet.bytes);
            var recipients = packet.recipients.iterator();
            while (recipients.next()) |recipient| try self.apply(recipient.index, header.id, header.body);
        }
    }

    fn seenOf(self: *Fixture, client: usize, network_id: i32) *Seen {
        const slot: usize = entities.Entities.slotOfNetwork(network_id);
        return &self.seen[client * self.slots + slot];
    }

    fn apply(self: *Fixture, client: usize, id: i32, payload: []const u8) !void {
        if (id == Client.packetId(.spawn_entity)) {
            const entity, const a = try Client.packet_spawn_entity.read(payload).entityId();
            _, const b = try a.objectUUID();
            _, const c = try b.type();
            const x, const d = try c.x();
            const y, const e = try d.y();
            const z, _ = try e.z();
            const seen = self.seenOf(client, entity);
            try std.testing.expect(!seen.known);
            seen.* = .{ .known = true, .position = .{ x, y, z } };
        } else if (id == Client.packetId(.entity_destroy)) {
            var ids = try Client.packet_entity_destroy.read(payload).entityIds();
            while (try ids.next()) |element| {
                const entity, const read_done = try element.value();
                try ids.advance(read_done);
                const seen = self.seenOf(client, entity);
                try std.testing.expect(seen.known);
                seen.known = false;
            }
        } else if (id == Client.packetId(.rel_entity_move)) {
            const entity, const a = try Client.packet_rel_entity_move.read(payload).entityId();
            const dx, const b = try a.dX();
            const dy, const c = try b.dY();
            const dz, _ = try c.dZ();
            moveBy(self.seenOf(client, entity), .{ dx, dy, dz });
        } else if (id == Client.packetId(.entity_move_look)) {
            const entity, const a = try Client.packet_entity_move_look.read(payload).entityId();
            const dx, const b = try a.dX();
            const dy, const c = try b.dY();
            const dz, const d = try c.dZ();
            const yaw, _ = try d.yaw();
            const seen = self.seenOf(client, entity);
            moveBy(seen, .{ dx, dy, dz });
            seen.yaw = yaw;
        } else if (id == Client.packetId(.entity_look)) {
            const entity, const a = try Client.packet_entity_look.read(payload).entityId();
            const yaw, _ = try a.yaw();
            self.seenOf(client, entity).yaw = yaw;
        } else if (id == Client.packetId(.sync_entity_position)) {
            const entity, const a = try Client.packet_sync_entity_position.read(payload).entityId();
            const x, const b = try a.x();
            const y, const c = try b.y();
            const z, _ = try c.z();
            const seen = self.seenOf(client, entity);
            try std.testing.expect(seen.known);
            seen.position = .{ x, y, z };
        }
    }

    /// VecDeltaCodec.decode on the client: an axis that did not move keeps its base.
    fn moveBy(seen: *Seen, delta: [3]i16) void {
        std.debug.assert(seen.known);
        for (&seen.position, delta) |*axis, by| {
            if (by != 0) axis.* = @as(f64, @floatFromInt(@as(i64, @intFromFloat(@round(axis.* * 4096.0))) + by)) / 4096.0;
        }
    }

    /// Every client knows a marker exactly when tracking says it has it, and one not behind sees
    /// it where the sync last sent it, as the packet codec rounds.
    fn check(self: *Fixture) !void {
        for (0..self.records.len) |client| {
            for (0..self.entities.directory.high()) |slot_index| {
                const slot: u32 = @intCast(slot_index);
                const seen = self.seen[client * self.slots + slot];
                const known = self.tracking.known(slot).contains(client);
                try std.testing.expectEqual(known, seen.known);
                if (!known or self.tracking.stale(slot).contains(client)) continue;
                const base = self.sync.views.at(slot).base;
                for (seen.position, base) |got, want| try std.testing.expectApproxEqAbs(want, got, 1.0 / 4096.0);
            }
        }
    }
};

test "clients see a kind on the shared ServerEntity as tracking and the sync say they have it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u64{ 7, 23, 42 }) |seed| try run(arena.allocator(), seed);
}

fn run(allocator: std.mem.Allocator, seed: u64) !void {
    var fixture: Fixture = undefined;
    try fixture.init(allocator, 4, seed);
    for (0..800) |tick| {
        // Now and then a client has no room, misses deltas, and is caught up once it has.
        for (0..fixture.records.len) |client| fixture.open(client, (tick + client) % 37 >= 3);
        try fixture.stir();
        try fixture.step();
        try fixture.check();
    }
}
