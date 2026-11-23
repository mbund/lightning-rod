//! What vanilla keeps for each player beside the engine record: game mode, health,
//! abilities, the selected hotbar slot and experience. Slots match the engine's, and so
//! does the life of a record: it starts when the player joins and ends when it leaves.
const std = @import("std");
const assert = std.debug.assert;
const persistent_records = @import("records");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_1_21_9 = @import("wire_1_21_9");
const worlds = @import("worlds");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const minecraft_packets = @import("minecraft_packets");
const lightning_rod = @import("lightning_rod");
const default_worlds = @import("vanilla_world").default_worlds;
const experience = @import("experience_state.zig");
const Input = @import("players").input.Input;
const Spawn = @import("vanilla_world").spawn.Spawn;
const WorldBorder = @import("vanilla_world").world_border.WorldBorder;
const Players = @import("players").players.Players;
const Player = Players.Player;

pub const PlayerStates = struct {
    pub const id = "minecraft:player_states";

    pub const Configuration = struct {
        /// The game mode of players with nothing saved.
        gamemode: minecraft.GameMode = .creative,
    };

    pub const Dependencies = struct {
        record_workspaces: *persistent_records.Workspaces,
        players: *Players,
        input: *Input,
        packets: *minecraft_packets.Packets,
        storage: lightning_rod.storage.Space,
        worlds: *worlds.Worlds,
        vanilla_worlds: *default_worlds.VanillaWorlds,
        world_border: *WorldBorder,
        spawn: ?*Spawn = null,
    };

    /// Version, health, game mode, selected slot and whether the player flies.
    pub const encoded_size = 8;
    /// The format this build writes. Version 1, written before flight was kept, lacks the last
    /// byte and reads as not flying.
    const encoded_version = 2;
    const encoded_size_1 = 7;

    pub const State = struct {
        /// Kept here because the engine record is empty by the time a departure is heard.
        uuid: u128 = 0,
        gamemode: minecraft.GameMode = .creative,
        health: f32 = 20,
        health_sent: f32 = 20,
        gamemode_sent: ?minecraft.GameMode = null,
        abilities_sent: ?u8 = null,
        flying: bool = false,
        selected_slot: u4 = 0,
        experience: experience.State = .{},
        experience_delay: u8 = 0,
        /// The engine's counts when the client was last told this state.
        arrivals: u32 = 0,
        sending: Sending = .done,
        saved: [encoded_size]u8 = @splat(0),
        saved_experience: [experience.State.encoded_size]u8 = @splat(0),

        pub fn encode(state: *const State) [encoded_size]u8 {
            assert(state.selected_slot <= 8);
            var bytes: [encoded_size]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            writer.writeByte(encoded_version) catch unreachable;
            writer.writeInt(u32, @bitCast(state.health), .little) catch unreachable;
            writer.writeByte(@intCast(@backingInt(state.gamemode))) catch unreachable;
            writer.writeByte(state.selected_slot) catch unreachable;
            writer.writeByte(@intFromBool(state.flying)) catch unreachable;
            assert(writer.end == bytes.len);
            return bytes;
        }

        fn decode(state: *State, bytes: []const u8) !void {
            var reader = std.Io.Reader.fixed(bytes);
            const version = try reader.takeByte();
            const expected_size: usize = switch (version) {
                1 => encoded_size_1,
                encoded_version => encoded_size,
                else => return error.CorruptPlayer,
            };
            if (bytes.len != expected_size) return error.CorruptPlayer;
            const health: f32 = @bitCast(try reader.takeInt(u32, .little));
            if (!std.math.isFinite(health) or health < 0 or health > 20) return error.CorruptPlayer;
            const gamemode = std.enums.fromInt(minecraft.GameMode, try reader.takeByte()) orelse return error.CorruptPlayer;
            const selected_slot = try reader.takeByte();
            if (selected_slot > 8) return error.CorruptPlayer;
            const flying = if (version == 1) false else switch (try reader.takeByte()) {
                0 => false,
                1 => true,
                else => return error.CorruptPlayer,
            };
            assert(reader.seek == bytes.len);
            state.health = health;
            state.health_sent = health;
            state.gamemode = gamemode;
            state.selected_slot = @intCast(selected_slot);
            // Game mode rules still apply once the player is in play: only creative players and
            // spectators fly.
            state.flying = flying;
            // An older record is written again in this format only once something changes.
            state.saved = state.encode();
        }
    };

    /// What the client still has to hear after it arrives somewhere.
    const Sending = enum { done, spawn, health, selection };

    deps: Dependencies,
    config: Configuration,
    records: []State,

    pub fn experienceKey(uuid: u128) [17]u8 {
        var key: [17]u8 = undefined;
        key[0] = 1;
        std.mem.writeInt(u128, key[1..17], uuid, .little);
        return key;
    }

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*PlayerStates {
        const self = try allocator.create(PlayerStates);
        const records = try allocator.alloc(State, deps.players.records.len);
        @memset(records, .{});
        self.* = .{ .deps = deps, .config = config, .records = records };
        deps.players.setRules(.init(PlayerStates, self, gameModeOf, spawnWorld, spawnPoint));
        try deps.players.observePresence(PlayerStates, self, onPresence);
        try deps.input.on(.client_command, self, onClientCommand);
        try deps.input.on(.held_item_slot, self, onHeldSlot);
        try deps.input.on(.abilities, self, onAbilities);
        return self;
    }

    /// Starting only registers handlers, so a reservation can run it before storage opens.
    pub const allocate = init;

    /// The state of a connected player.
    pub fn of(self: *PlayerStates, player: *const Player) *State {
        const state = &self.records[player.handle.?.index];
        assert(state.uuid == player.uuid);
        return state;
    }

    fn gameModeOf(self: *PlayerStates, slot: usize) minecraft.GameMode {
        return self.records[slot].gamemode;
    }

    fn spawnWorld(self: *PlayerStates) u32 {
        return self.deps.vanilla_worlds.overworld;
    }

    fn spawnPoint(self: *PlayerStates, player: *const Player) !?Players.Rules.Spawn {
        const spawn = self.deps.spawn orelse return null;
        const selected = try spawn.select(player.world, self.config.gamemode, self.deps.world_border.bounds(player.world));
        return .{ .position = selected.position, .rotation = selected.rotation };
    }

    fn onPresence(self: *PlayerStates, events: []const sessions.Event) !void {
        const table = persistent_records.Table.init(self.deps.storage, self.deps.record_workspaces.resources);
        var keys: [64][17]u8 = undefined;
        var values: [64][@max(encoded_size, experience.State.encoded_size)]u8 = undefined;
        var reads: [64]persistent_records.Get = undefined;
        var writes: [64]persistent_records.Write = undefined;
        var lengths: [64]?usize = undefined;
        var begin: usize = 0;
        while (begin < events.len) {
            const kind = std.meta.activeTag(events[begin]);
            var end = begin;
            while (end < events.len and end - begin < keys.len / 2 and std.meta.activeTag(events[end]) == kind) end += 1;
            const batch = events[begin..end];
            begin = end;
            switch (kind) {
                .joined => {
                    for (batch, 0..) |event, index| {
                        std.mem.writeInt(u128, keys[index * 2][0..16], event.joined.uuid, .little);
                        keys[index * 2 + 1] = experienceKey(event.joined.uuid);
                        reads[index * 2] = .{ .key = keys[index * 2][0..16], .destination = &values[index * 2] };
                        reads[index * 2 + 1] = .{ .key = &keys[index * 2 + 1], .destination = &values[index * 2 + 1] };
                    }
                    try table.getBatch(reads[0 .. batch.len * 2], lengths[0 .. batch.len * 2]);
                    for (batch, 0..) |event, index| {
                        const state = &self.records[event.joined.handle.index];
                        state.* = .{ .uuid = event.joined.uuid, .gamemode = self.config.gamemode };
                        if (lengths[index * 2]) |length| try state.decode(values[index * 2][0..length]);
                        self.deps.players.records[event.joined.handle.index].occluded = state.gamemode != .spectator;
                        if (lengths[index * 2 + 1]) |length| {
                            state.experience = try experience.State.decode(values[index * 2 + 1][0..length]);
                            @memcpy(&state.saved_experience, values[index * 2 + 1][0..length]);
                        }
                    }
                },
                .left => {
                    var count: usize = 0;
                    for (batch) |event| {
                        const state = &self.records[event.left.index];
                        assert(state.uuid != 0);
                        const body = state.encode();
                        if (!std.mem.eql(u8, &body, &state.saved)) {
                            @memcpy(values[count][0..body.len], &body);
                            std.mem.writeInt(u128, keys[count][0..16], state.uuid, .little);
                            writes[count] = .{ .key = keys[count][0..16], .value = values[count][0..body.len] };
                            count += 1;
                        }
                        const points = state.experience.encode();
                        if (!std.mem.eql(u8, &points, &state.saved_experience)) {
                            @memcpy(values[count][0..points.len], &points);
                            keys[count] = experienceKey(state.uuid);
                            writes[count] = .{ .key = &keys[count], .value = values[count][0..points.len] };
                            count += 1;
                        }
                        state.* = .{};
                    }
                    try table.putBatch(writes[0..count]);
                },
                .ready, .input => {},
            }
        }
    }

    pub fn checkpoint(self: *PlayerStates, space: lightning_rod.storage.Space) !void {
        const table = persistent_records.Table.init(space, self.deps.record_workspaces.resources);
        var keys: [256][17]u8 = undefined;
        var writes: [256]persistent_records.Write = undefined;
        var count: usize = 0;
        errdefer space.fail();
        for (self.deps.players.activeSlots()) |index| {
            const state = &self.records[index];
            if (writes.len - count < 2) {
                try table.putBatch(writes[0..count]);
                count = 0;
            }
            const bytes = state.encode();
            if (!std.mem.eql(u8, &bytes, &state.saved)) {
                state.saved = bytes;
                std.mem.writeInt(u128, keys[count][0..16], state.uuid, .little);
                writes[count] = .{ .key = keys[count][0..16], .value = &state.saved };
                count += 1;
            }
            const points = state.experience.encode();
            if (!std.mem.eql(u8, &points, &state.saved_experience)) {
                state.saved_experience = points;
                keys[count] = experienceKey(state.uuid);
                writes[count] = .{ .key = &keys[count], .value = &state.saved_experience };
                count += 1;
            }
        }
        if (count != 0) try table.putBatch(writes[0..count]);
    }

    pub fn tick(self: *PlayerStates) !void {
        const players = self.deps.players;
        for (players.activeSlots()) |index| {
            const player = &players.records[index];
            const handle = player.handle orelse continue;
            if (player.configuring or player.stage != .ready) continue;
            const state = &self.records[index];
            if (state.arrivals != player.arrivals) {
                state.arrivals = player.arrivals;
                // A client that arrives somewhere is told the spawn again, as vanilla sends it
                // with every arrival in a world.
                state.sending = .spawn;
            }
            while (state.sending != .done) {
                switch (state.sending) {
                    .spawn => {
                        if (!try self.sendSpawn(player)) break;
                        state.sending = .health;
                    },
                    .health => {
                        if (!self.sendHealth(player, state.health)) break;
                        state.health_sent = state.health;
                        state.sending = .selection;
                    },
                    .selection => {
                        if (!players.sendPacket(writeSelectedSlot, player.protocol, handle, .{state.selected_slot})) break;
                        state.sending = .done;
                    },
                    .done => unreachable,
                }
            }
            if (state.sending != .done) continue;
            if (state.gamemode == .spectator) state.flying = true;
            if (state.gamemode == .survival or state.gamemode == .adventure) state.flying = false;
            const abilities: u8 = switch (state.gamemode) {
                .creative => 13 | (@as(u8, @intFromBool(state.flying)) << 1),
                .spectator => 7,
                .survival, .adventure => 0,
            };
            if (state.gamemode_sent != state.gamemode) {
                const targets = [_]sessions.Service.Target{.{ .handle = handle, .protocol = player.protocol }};
                var delivered: [1]sessions.Service.Delivery = undefined;
                try self.deps.packets.fanoutGroup(.{ writeAbilities, writeGameMode }, &targets, .{ .{abilities}, .{state.gamemode} }, &.{ 32, 16 }, &delivered);
                if (delivered[0] != .queued) continue;
                state.abilities_sent = abilities;
                state.gamemode_sent = state.gamemode;
            } else if (state.abilities_sent != abilities) {
                if (!players.sendPacket(writeAbilities, player.protocol, handle, .{abilities})) continue;
                state.abilities_sent = abilities;
            }
        }
    }

    pub fn setGameMode(self: *PlayerStates, player: *Player, mode: minecraft.GameMode) bool {
        const state = self.of(player);
        if (state.gamemode == mode) return false;
        state.gamemode = mode;
        state.flying = mode == .spectator or (mode == .creative and state.flying);
        player.flags.invisible = mode == .spectator;
        player.occluded = mode != .spectator;
        player.revision += 1;
        return true;
    }

    /// Tells a client the world's spawn, which its compass points to: since 1.21.9 vanilla keeps
    /// one for the whole server, in the overworld, whichever world the player is in.
    fn sendSpawn(self: *PlayerStates, player: *const Player) !bool {
        const overworld = self.deps.vanilla_worlds.overworld;
        const world = self.deps.worlds.get(overworld) orelse return true;
        const at: [3]i32, const angle: f32 = if (self.deps.spawn) |spawn| point: {
            const definition = try spawn.get(overworld);
            break :point .{ .{ definition.position.x, definition.position.y, definition.position.z }, definition.angle };
        } else point: {
            const position = self.deps.players.config.spawn orelse minecraft.Position{ .x = 0.5, .y = 65, .z = 0.5 };
            break :point .{ .{ @intFromFloat(@floor(position.x)), @intFromFloat(@floor(position.y)), @intFromFloat(@floor(position.z)) }, 0 };
        };
        return self.deps.players.sendPacket(writeSpawn, player.protocol, player.handle.?, .{ world.name, at, angle });
    }

    pub fn sendHealth(self: *PlayerStates, player: *const Player, health: f32) bool {
        return self.deps.players.sendPacket(writeHealth, player.protocol, player.handle.?, .{health});
    }

    fn onClientCommand(self: *PlayerStates, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_client_command.Reader) !void {
        const action, const done = body.actionId() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const player = &self.deps.players.records[handle.index];
        const state = &self.records[handle.index];
        // Only the dead respawn.
        if (action != 0 or state.health != 0 or player.stage != .ready) return;
        try self.deps.players.respawn(player);
        state.health = 20;
        state.health_sent = 20;
    }

    fn onHeldSlot(self: *PlayerStates, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_held_item_slot.Reader) !void {
        const slot, const done = body.slotId() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        if (slot >= 0 and slot <= 8) self.records[handle.index].selected_slot = @intCast(slot);
    }

    fn onAbilities(self: *PlayerStates, handle: sessions.Handle, body: wire_1_21_5.play.toServer.packet_abilities.Reader) !void {
        const flags, const done = body.flags() catch return error.InvalidPacket;
        done.finish() catch return error.InvalidPacket;
        const state = &self.records[handle.index];
        state.flying = state.gamemode == .spectator or (state.gamemode == .creative and flags & 2 != 0);
    }

    const writeSpawn = .{ writeSpawn_1_21_5, writeSpawn_1_21_9 };

    fn writeSpawn_1_21_5(packet: wire_1_21_5.play.toClient.packet_spawn_position.Writer, _: []const u8, at: [3]i32, angle: f32) ![]u8 {
        const located = try packet.location(.{ .x = at[0], .y = @intCast(at[1]), .z = at[2] });
        return (try located.angle(angle)).finish();
    }

    /// Since 1.21.9 the spawn names its world and has a pitch beside the angle.
    fn writeSpawn_1_21_9(packet: wire_1_21_9.play.toClient.packet_spawn_position.Writer, world: []const u8, at: [3]i32, angle: f32) ![]u8 {
        var global = try packet.globalPos();
        const located = try minecraft_packets.nested(.{writeGlobalPos}).write(try global.begin(), .{ world, at });
        const placed = try global.advance(located);
        return (try (try placed.yaw(angle)).pitch(0)).finish();
    }

    fn writeGlobalPos(packet: wire_1_21_9.GlobalPos.Writer, args: struct { []const u8, [3]i32 }) !wire_1_21_9.GlobalPos.Writer.Done {
        const named = try packet.dimensionName(args[0]);
        return named.location(.{ .x = args[1][0], .y = @intCast(args[1][1]), .z = args[1][2] });
    }

    fn writeSelectedSlot(packet: wire_1_21_5.play.toClient.packet_held_item_slot.Writer, slot: u4) ![]u8 {
        assert(slot <= 8);
        return (try packet.slot(slot)).finish();
    }

    fn writeHealth(packet: wire_1_21_5.play.toClient.packet_update_health.Writer, health: f32) ![]u8 {
        const value = try packet.health(health);
        const food = try value.food(20);
        return (try food.foodSaturation(5)).finish();
    }

    fn writeAbilities(packet: wire_1_21_5.play.toClient.packet_abilities.Writer, flags: u8) ![]u8 {
        const enabled = try packet.flags(@bitCast(flags));
        const flying = try enabled.flyingSpeed(0.05);
        return (try flying.walkingSpeed(0.1)).finish();
    }

    fn writeGameMode(packet: wire_1_21_5.play.toClient.packet_game_state_change.Writer, mode: minecraft.GameMode) ![]u8 {
        const reason = try packet.reason(3);
        return (try reason.gameMode(@floatFromInt(@backingInt(mode)))).finish();
    }
};

test "vanilla player state survives leaving, checkpoints and restarts, and corrupt records are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/player-states", .{temporary.sub_path});
    var store = try lightning_rod.storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer store.deinit();
    const resources = try persistent_records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 });
    defer resources.deinit();
    var workspaces: persistent_records.Workspaces = .{ .resources = resources };
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
    const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
    var rows: [2]Player = @splat(.{});
    // Players reads what sessions knew of a player as it joins; these know nothing.
    var no_sessions: sessions.Service = undefined;
    no_sessions.profiles = &.{};
    var players: Players = .{
        .deps = .{ .sessions = &no_sessions, .packets = undefined, .input = undefined, .storage = try store.openSpace(Players.id), .worlds = dimensions, .record_workspaces = &workspaces },
        .config = .{},
        .spawn_world = world,
        .records = &rows,
        .dig_handlers = &.{},
    };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const space = try store.openSpace(PlayerStates.id);
    var states: [2]PlayerStates.State = @splat(.{});
    var player_states: PlayerStates = .{
        .deps = .{ .record_workspaces = &workspaces, .players = &players, .input = undefined, .packets = undefined, .storage = space, .worlds = dimensions, .vanilla_worlds = undefined, .world_border = undefined },
        .config = .{ .gamemode = .survival },
        .records = &states,
    };
    try players.observePresence(PlayerStates, &player_states, PlayerStates.onPresence);
    var joins: [2]sessions.Event = undefined;
    var departures: [2]sessions.Event = undefined;
    for (&joins, &departures, 0..) |*join, *departure, index| {
        const handle: sessions.Handle = .{ .index = @intCast(index), .generation = 1 };
        join.* = .{ .joined = .{ .handle = handle, .uuid = index + 1, .protocol = 0, .name = @splat(0), .name_len = 1 } };
        departure.* = .{ .left = handle };
    }

    try players.onLifecycle(&joins);
    for (states, rows) |state, row| {
        try std.testing.expectEqual(row.uuid, state.uuid);
        try std.testing.expectEqual(minecraft.GameMode.survival, state.gamemode);
        try std.testing.expectEqual(@as(f32, 20), state.health);
        try std.testing.expect(row.occluded);
    }
    states[0].health = 7;
    states[0].selected_slot = 4;
    states[0].experience.points(50);
    const points = states[0].experience;
    try std.testing.expect(player_states.setGameMode(&rows[0], .creative));
    states[0].flying = true;
    try std.testing.expect(player_states.setGameMode(&rows[1], .spectator));

    try players.onLifecycle(&departures);
    for (states) |state| try std.testing.expectEqual(@as(u128, 0), state.uuid);
    try players.onLifecycle(&joins);
    try std.testing.expectEqual(@as(f32, 7), states[0].health);
    try std.testing.expectEqual(@as(u4, 4), states[0].selected_slot);
    try std.testing.expectEqualDeep(points, states[0].experience);
    // A creative player flying when it left flies when it comes back.
    try std.testing.expect(states[0].flying);
    try std.testing.expectEqual(minecraft.GameMode.spectator, states[1].gamemode);
    try std.testing.expect(!rows[1].occluded);

    // A restart keeps what the last checkpoint wrote, as nobody left, as a reload does.
    states[0].health = 3;
    states[0].flying = false;
    try player_states.checkpoint(space);
    rows = @splat(.{});
    states = @splat(.{});
    try players.onLifecycle(&joins);
    try std.testing.expectEqual(@as(f32, 3), states[0].health);
    try std.testing.expect(!states[0].flying);

    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, 1, .little);
    var corrupt = states[0].encode();
    std.mem.writeInt(u32, corrupt[1..5], @bitCast(@as(f32, 25)), .little);
    try persistent_records.Table.init(space, resources).put(&key, &corrupt);
    rows = @splat(.{});
    states = @splat(.{});
    try std.testing.expectError(error.CorruptPlayer, players.onLifecycle(joins[0..1]));
}

test "player state records of the first format read as not flying, and malformed ones are refused" {
    // Version 1: health 12.5, creative, slot 3, from before flight was kept.
    var first: [PlayerStates.encoded_size_1]u8 = .{ 1, 0, 0, 0, 0, 1, 3 };
    std.mem.writeInt(u32, first[1..5], @bitCast(@as(f32, 12.5)), .little);
    var state: PlayerStates.State = .{};
    try state.decode(&first);
    try std.testing.expectEqual(@as(f32, 12.5), state.health);
    try std.testing.expectEqual(minecraft.GameMode.creative, state.gamemode);
    try std.testing.expectEqual(@as(u4, 3), state.selected_slot);
    try std.testing.expect(!state.flying);
    // Nothing changed, so nothing is written until something does.
    try std.testing.expectEqualSlices(u8, &state.encode(), &state.saved);

    state.flying = true;
    const second = state.encode();
    var read: PlayerStates.State = .{};
    try read.decode(&second);
    try std.testing.expect(read.flying);

    var bad = second;
    bad[bad.len - 1] = 2;
    try std.testing.expectError(error.CorruptPlayer, read.decode(&bad));
    try std.testing.expectError(error.CorruptPlayer, read.decode(second[0 .. second.len - 1]));
    try std.testing.expectError(error.CorruptPlayer, read.decode(first[0 .. first.len - 1]));
    var unknown = second;
    unknown[0] = 3;
    try std.testing.expectError(error.CorruptPlayer, read.decode(&unknown));
}
