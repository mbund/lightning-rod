//! A kind its clients step, on the shared ServerEntity: drifters that glide and slow, which
//! clients step themselves from what they are sent, and otherwise than the server does. A client
//! moves one only on the ticks its own tick count allows, which began when it was sent it, while
//! the server moves it every tick, and now and then the server alone knocks one. Clients are
//! modelled from the packets they get, stepping as such a client does, and every tick each one is
//! held to its class's model to the bit, and the model to the drifter within the tolerance.

const std = @import("std");
const entities = @import("entities");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocols = @import("minecraft_packets").protocols;
const minecraft = @import("minecraft_model");
const Players = @import("players").players.Players;
const Tracking = @import("tracking.zig").Tracking;
const entity_sync = @import("entity_sync.zig");
const models_module = @import("models.zig");

const Model = models_module.Model;
const Classes = models_module.Classes;
const Client = protocols.implementations[0].Protocol.play.toClient;

const Drifter = struct {
    pub const Data = struct { flags: i8 = 0 };

    fn writeData(_: *Fixture, entries: *entity_sync.Entries, data: Data, changes: Sync.DataChanges) !void {
        if (changes.contains(.flags)) try entries.putByte(0, data.flags);
    }

    const Sync = entity_sync.EntitySync(Data, Fixture);
    const kind = 1;
    const phases = 2;

    /// A drifter's tick as the server steps it: it glides and slows every tick.
    fn server(model: Model) Model {
        var next = model;
        for (&next.position, &next.velocity) |*axis, *motion| {
            axis.* += motion.*;
            motion.* *= 0.5;
        }
        return next;
    }

    /// As a client steps it: only on the ticks its tick count and the drifter's id allow.
    fn client(model: Model, ticks: u32, slot: u32) Model {
        if ((ticks + slot) % phases != 0) return model;
        return server(model);
    }
};

/// What a client knows of one drifter, from the packets it got, and its tick count.
const Seen = struct { known: bool = false, ticks: u32 = 0, model: Model = .{ .position = .{ 0, 0, 0 }, .velocity = .{ 0, 0, 0 }, .on_ground = false } };

const Fixture = struct {
    allocator: std.mem.Allocator,
    service: *sessions.Service,
    entities: *entities.Entities,
    records: []Players.Player,
    players: Players,
    tracking: *Tracking,
    sync: Drifter.Sync,
    random: std.Random.DefaultPrng,
    live: std.ArrayList(u64) = .empty,
    next_id: u64 = 1,
    seen: []Seen,
    truth: []Model,
    data: []Drifter.Data,
    /// Knocked by the server alone this tick.
    knocked: []bool,
    slots: usize,
    /// Corrections clients were sent: exact states, and motion alone.
    sent_exact: usize = 0,
    sent_motion: usize = 0,

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
            .truth = undefined,
            .data = undefined,
            .knocked = undefined,
            .slots = owned.directory.capacity(),
        };
        self.players.setRules(.init(Fixture, self, gameMode, spawnWorld, spawnPoint));
        self.players.entities = owned;
        try self.players.initIndexes(allocator);
        try self.players.rebuildIndexes();
        self.tracking = try Tracking.init(allocator, .{}, .{ .entities = owned, .players = &self.players });
        const tracker = try self.tracking.register(.{ .kinds = .of(&.{Drifter.kind}), .range = 64 });
        self.sync = try .init(allocator, .{ .visits = true }, .{ .players = &self.players, .sessions = service, .packets = packet_api, .tracking = self.tracking, .tracker = tracker, .pool = &owned.pool, .slots = self.slots }, .{ .kind = self, .write_data = Drifter.writeData, .body = body, .identity = identity, .client = .{ .simulates = .{ .models = .{ .phases = Drifter.phases } } }, .before = before });
        self.seen = try allocator.alloc(Seen, count * self.slots);
        @memset(self.seen, .{});
        self.truth = try allocator.alloc(Model, self.slots);
        self.data = try allocator.alloc(Drifter.Data, self.slots);
        self.knocked = try allocator.alloc(bool, self.slots);
        @memset(self.knocked, false);
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

    fn before(self: *Fixture, a: u32, b: u32) bool {
        return self.entities.directory.entry(a).id < self.entities.directory.entry(b).id;
    }

    fn kick(self: *Fixture) [3]f64 {
        const random = self.random.random();
        return .{ (random.float(f64) - 0.5) * 0.8, 0, (random.float(f64) - 0.5) * 0.8 };
    }

    /// Drifters come and go and change their data, and the server knocks some.
    fn stir(self: *Fixture) !void {
        const random = self.random.random();
        if (random.uintLessThan(u8, 3) == 0) {
            const id = self.next_id;
            self.next_id += 1;
            const at: [3]f64 = .{ (random.float(f64) - 0.5) * 200, 64, (random.float(f64) - 0.5) * 200 };
            const slot = try self.entities.enter(id, Drifter.kind);
            try self.entities.places.insert(id, 0, at, .{ .kind = Drifter.kind, .half_width = 0.25, .height = 0.5 });
            self.truth[slot] = .{ .position = at, .velocity = self.kick(), .on_ground = false };
            self.data[slot] = .{};
            self.knocked[slot] = false;
            try self.live.append(self.allocator, id);
        }
        if (self.live.items.len > 0 and random.uintLessThan(u8, 6) == 0) {
            const id = self.live.swapRemove(random.uintLessThan(usize, self.live.items.len));
            const slot = self.entities.directory.slotOf(id).?;
            self.entities.places.remove(id);
            self.entities.leave(slot);
        }
        for (self.live.items) |id| {
            const slot = self.entities.directory.slotOf(id).?;
            if (random.uintLessThan(u8, 40) == 0) {
                self.data[slot].flags ^= 1;
                self.sync.mark(slot);
            }
            if (random.uintLessThan(u8, 30) == 0) {
                self.truth[slot].velocity = self.kick();
                // Now and then far off, in and out of players' range.
                if (random.uintLessThan(u8, 4) == 0) self.truth[slot].position = .{ (random.float(f64) - 0.5) * 200, 64, (random.float(f64) - 0.5) * 200 };
                self.knocked[slot] = true;
                self.sync.mark(slot);
            }
        }
    }

    /// One tick: each client steps what it knows, then the server steps each drifter and its
    /// models, then tracking, the sync, and the packets read.
    fn step(self: *Fixture) !void {
        for (self.records) |*record| record.client_ticks += 1;
        for (0..self.records.len) |client| for (0..self.entities.directory.high()) |slot| {
            const seen = &self.seen[client * self.slots + slot];
            if (!seen.known) continue;
            seen.ticks += 1;
            seen.model = Drifter.client(seen.model, seen.ticks, @intCast(slot));
        };
        const models = &self.sync.models.?;
        std.mem.sort(u64, self.live.items, {}, std.sort.asc(u64));
        for (self.live.items) |id| {
            const slot = self.entities.directory.slotOf(id).?;
            // A knock is what the server alone did: it is not stepped from what clients have.
            if (!self.knocked[slot]) self.truth[slot] = Drifter.server(self.truth[slot]);
            try self.entities.places.moveById(id, 0, self.truth[slot].position);
            if (try models.begin(slot, id)) |entries| {
                for (entries) |entry| {
                    var left = entry.classes;
                    while (left != 0) {
                        const first: u8 = @ctz(left);
                        var alike: Classes = 0;
                        var each = left;
                        while (each != 0) : (each &= each - 1) {
                            const class: u8 = @ctz(each);
                            if ((models.ticksOf(class) + slot) % Drifter.phases == (models.ticksOf(first) + slot) % Drifter.phases) alike |= @as(Classes, 1) << @intCast(class);
                        }
                        left &= ~alike;
                        models.put(Drifter.client(entry.model, models.ticksOf(first), slot), alike, false);
                    }
                }
                models.judge(self.truth[slot]);
            }
            // It moves: its backstop is due while it does.
            self.sync.stir(slot);
        }
        try self.players.rebuildIndexes();
        try self.tracking.tick();
        try self.sync.begin();
        var changes = self.tracking.changesOf(0);
        while (changes.next()) |change| if (change.gone) try self.sync.gone(change.slot);
        for (self.sync.collect()) |slot| {
            const entry = self.entities.directory.entry(slot);
            if (entry.id == 0 or entry.retired) continue;
            try self.sync.update(slot, .{ .id = entry.id, .data = self.data[slot], .changed = self.tracking.changed(slot) != null, .impulse = self.knocked[slot] });
            self.knocked[slot] = false;
        }
        try self.sync.finish();
        try self.read();
    }

    fn identity(self: *Fixture, slot: u32) Drifter.Sync.Identity {
        return .{ .uuid = self.entities.directory.entry(slot).id, .entity_type = 0 };
    }

    fn body(self: *Fixture, slot: u32) Drifter.Sync.Body {
        const truth = self.truth[slot];
        return .{ .position = truth.position, .velocity = truth.velocity, .yaw = 0, .pitch = 0, .on_ground = truth.on_ground };
    }

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
            // Entity.recreateFromPacket: where it is, its velocity as the packet rounds it, and in
            // the air; its tick count begins.
            const entity, const a = try Client.packet_spawn_entity.read(payload).entityId();
            _, const b = try a.objectUUID();
            _, const c = try b.type();
            const x, const d = try c.x();
            const y, const e = try d.y();
            const z, const f = try e.z();
            _, const g = try f.pitch();
            _, const h = try g.yaw();
            _, const i = try h.headPitch();
            _, const j = try i.objectData();
            const seen = self.seenOf(client, entity);
            try std.testing.expect(!seen.known);
            var motion = try j.velocity();
            const vx, const k = try (try motion.begin()).x();
            const vy, const l = try k.y();
            const vz, const m = try l.z();
            _ = try motion.advance(m);
            seen.* = .{ .known = true, .model = .{ .position = .{ x, y, z }, .velocity = .{ shortVelocity(vx), shortVelocity(vy), shortVelocity(vz) }, .on_ground = false } };
        } else if (id == Client.packetId(.entity_destroy)) {
            var ids = try Client.packet_entity_destroy.read(payload).entityIds();
            while (try ids.next()) |element| {
                const entity, const read_done = try element.value();
                try ids.advance(read_done);
                const seen = self.seenOf(client, entity);
                try std.testing.expect(seen.known);
                seen.known = false;
            }
        } else if (id == Client.packetId(.entity_teleport)) {
            const entity, const a = try Client.packet_entity_teleport.read(payload).entityId();
            const x, const b = try a.x();
            const y, const c = try b.y();
            const z, const d = try c.z();
            const dx, const e = try d.dx();
            const dy, const f = try e.dy();
            const dz, const g = try f.dz();
            _, const h = try g.yaw();
            _, const i = try h.pitch();
            _, const j = try i.flags();
            const ground, _ = try j.onGround();
            const seen = self.seenOf(client, entity);
            try std.testing.expect(seen.known);
            self.sent_exact += 1;
            seen.model = .{ .position = .{ x, y, z }, .velocity = .{ dx, dy, dz }, .on_ground = ground };
        } else if (id == Client.packetId(.entity_velocity)) {
            // Entity.lerpMotion: how it moves, as the packet rounds it.
            const entity, const a = try Client.packet_entity_velocity.read(payload).entityId();
            const seen = self.seenOf(client, entity);
            try std.testing.expect(seen.known);
            self.sent_motion += 1;
            var motion = try a.velocity();
            const vx, const b = try (try motion.begin()).x();
            const vy, const c = try b.y();
            const vz, const d = try c.z();
            _ = try motion.advance(d);
            seen.model.velocity = .{ shortVelocity(vx), shortVelocity(vy), shortVelocity(vz) };
        } else if (id == Client.packetId(.rel_entity_move) or id == Client.packetId(.entity_move_look) or id == Client.packetId(.sync_entity_position)) {
            // Clients that step it are never sent where it moved by a delta.
            return error.TestUnexpectedResult;
        }
    }

    /// Every client knows a drifter exactly when tracking says it has it, and one not behind has
    /// its class's model to the bit, which is within the tolerance of the drifter.
    fn check(self: *Fixture) !void {
        const models = &self.sync.models.?;
        for (0..self.records.len) |client| {
            for (0..self.entities.directory.high()) |slot_index| {
                const slot: u32 = @intCast(slot_index);
                const seen = self.seen[client * self.slots + slot];
                const known = self.tracking.known(slot).contains(client);
                try std.testing.expectEqual(known, seen.known);
                if (!known or self.tracking.stale(slot).contains(client)) continue;
                const entry = self.entities.directory.entry(slot);
                // Gone, its removal still on its way: nothing steps it now.
                if (entry.id == 0 or entry.retired) continue;
                const id = entry.id;
                const model = models.lastModelOf(slot, id, models.classOf(slot, client)) orelse return error.TestUnexpectedResult;
                try std.testing.expect(model.eql(seen.model));
                try std.testing.expect(!model.apart(self.truth[slot], models.config.tolerance, false));
            }
        }
    }
};

test "clients that step a kind have their class's model to the bit, and it is near the entity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u64{ 7, 23, 42 }) |seed| {
        var fixture: Fixture = undefined;
        try fixture.init(arena.allocator(), 4, seed);
        for (0..800) |tick| {
            // Now and then a client has no room, misses an exact state, and is caught up once it has.
            for (0..fixture.records.len) |client| fixture.open(client, (tick + client) % 37 >= 3);
            try fixture.stir();
            try fixture.step();
            try fixture.check();
        }
        // Clients computed most ticks themselves, put right now and then, sometimes by their motion alone.
        try std.testing.expect(fixture.sent_exact > 0 and fixture.sent_motion > 0);
    }
}

test "classes split by phase and by rules, and share a model until their steps differ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 4, 1);
    const models = &fixture.sync.models.?;
    // Two phases by two ways a protocol rounds a velocity.
    try std.testing.expectEqual(@as(Classes, 0b1111), models.all());
    try std.testing.expectEqual(@as(u8, 1), models.phaseOf(1));
    try std.testing.expectEqual(@as(u8, 0), models.rulesOf(1));
    try std.testing.expectEqual(@as(u8, 1), models.roundingOf(2));
    const a: Model = .{ .position = .{ 1, 2, 3 }, .velocity = .{ 0.1, 0, 0 }, .on_ground = false };
    var b = a;
    b.position[0] += 0.05;
    try std.testing.expect(!b.apart(a, 1.0 / 16.0, false));
    b.velocity[0] += 0.02;
    try std.testing.expect(b.apart(a, 1.0 / 16.0, false));
    var c = a;
    c.position[0] = 0.999;
    try std.testing.expect(c.apart(a, 1.0 / 16.0, false));
}

test "a client that loses ticks or runs ahead is found once the shift outlasts jitter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 4, 3);
    var drift = try models_module.Drift.init(arena.allocator(), fixture.records.len);
    var random = std.Random.DefaultPrng.init(9);
    var found: [4]i64 = @splat(0);
    var ended: [4]u64 = @splat(0);
    for (0..400) |tick| {
        for (fixture.records, &ended, 0..) |*record, *count, player| {
            // Player 1 is frozen thirty ticks; player 2 runs ten ahead as its server lags.
            if (!(player == 1 and tick >= 50 and tick < 80)) count.* += if (player == 2 and tick >= 200 and tick < 210) 2 else 1;
            // Its tick ends are heard up to two ticks late, but never fewer than before.
            const late = random.random().uintLessThan(u64, 3);
            record.client_ticks = @max(record.client_ticks, count.* -| late);
        }
        for (drift.check(&fixture.players, tick)) |moved| found[moved.player] += moved.ticks;
    }
    try std.testing.expectEqual(@as(i64, 0), found[0]);
    try std.testing.expect(found[1] >= 28 and found[1] <= 32);
    try std.testing.expect(found[2] <= -8 and found[2] >= -12);
    try std.testing.expectEqual(@as(i64, 0), found[3]);
}

/// A velocity as the protocols before 1.21.9 carry it: shorts of eighths of a thousandth. The
/// clients here play the first protocol, which carries it so.
fn shortVelocity(value: i16) f64 {
    return @as(f64, @floatFromInt(value)) / 8000.0;
}

comptime {
    std.debug.assert(entity_sync.roundingOf(protocols.implementations[0].protocol_number) == 0);
}
