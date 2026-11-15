//! What vanilla keeps for each player beside the engine record: game mode, health,
//! abilities, the selected hotbar slot and experience. Slots match the engine's, and so
//! does the life of a record: it starts when the player joins and ends when it leaves.
const std = @import("std");
const assert = std.debug.assert;
const persistent_records = @import("records");
const wire_1_21_5 = @import("wire_1_21_5");
const worlds = @import("worlds");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const minecraft_packets = @import("minecraft_packets");
const lightning_rod = @import("lightning_rod");
const default_worlds = @import("vanilla_world").default_worlds;
const experience = @import("experience_state.zig");
const Input = @import("players").input.Input;
const Spawn = @import("vanilla_world").spawn.Spawn;
const Players = @import("players").players.Players;
const Player = Players.Player;

pub const PlayerStates = struct {
    pub const id = "minecraft:player_states";

    pub const Configuration = struct {
        /// The game mode of players with nothing saved.
        gamemode: minecraft.GameMode = .creative,
        /// A square border around the origin that players cannot cross.
        world_border: ?f64 = null,
    };

    pub const Dependencies = struct {
        record_workspaces: *persistent_records.Workspaces,
        players: *Players,
        input: *Input,
        packets: *minecraft_packets.Packets,
        storage: lightning_rod.storage.Space,
        worlds: *worlds.Worlds,
        vanilla_worlds: *default_worlds.VanillaWorlds,
        spawn: ?*Spawn = null,
    };

    /// Version, health, game mode and selected slot.
    pub const encoded_size = 7;

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
        life: u32 = 0,
        sending: Sending = .done,
        saved: [encoded_size]u8 = @splat(0),
        saved_experience: [experience.State.encoded_size]u8 = @splat(0),

        pub fn encode(state: *const State) [encoded_size]u8 {
            assert(state.selected_slot <= 8);
            var bytes: [encoded_size]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            writer.writeByte(1) catch unreachable;
            writer.writeInt(u32, @bitCast(state.health), .little) catch unreachable;
            writer.writeByte(@intCast(@backingInt(state.gamemode))) catch unreachable;
            writer.writeByte(state.selected_slot) catch unreachable;
            assert(writer.end == bytes.len);
            return bytes;
        }

        fn decode(state: *State, bytes: []const u8) !void {
            if (bytes.len != encoded_size) return error.CorruptPlayer;
            var reader = std.Io.Reader.fixed(bytes);
            if (try reader.takeByte() != 1) return error.CorruptPlayer;
            const health: f32 = @bitCast(try reader.takeInt(u32, .little));
            if (!std.math.isFinite(health) or health < 0 or health > 20) return error.CorruptPlayer;
            const gamemode = std.enums.fromInt(minecraft.GameMode, try reader.takeByte()) orelse return error.CorruptPlayer;
            const selected_slot = try reader.takeByte();
            if (selected_slot > 8) return error.CorruptPlayer;
            state.health = health;
            state.health_sent = health;
            state.gamemode = gamemode;
            state.selected_slot = @intCast(selected_slot);
            @memcpy(&state.saved, bytes);
        }
    };

    /// What the client still has to hear after it arrives somewhere.
    const Sending = enum { done, border, health, selection };

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
        if (config.world_border) |diameter| {
            const position = deps.players.config.spawn orelse minecraft.Position{ .x = 0.5, .y = 65, .z = 0.5 };
            if (!std.math.isFinite(diameter) or diameter < 1 or diameter > 60_000_000 or @abs(position.x) > diameter / 2 - 0.3 or @abs(position.z) > diameter / 2 - 0.3) return error.InvalidConfiguration;
        }
        const self = try allocator.create(PlayerStates);
        const records = try allocator.alloc(State, deps.players.records.len);
        @memset(records, .{});
        self.* = .{ .deps = deps, .config = config, .records = records };
        deps.players.setRules(.init(PlayerStates, self, gameModeOf, spawnWorld, spawnPoint, insideBorder));
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

    pub fn insideBorder(self: *const PlayerStates, position: minecraft.Position) bool {
        const diameter = self.config.world_border orelse return true;
        return @abs(position.x) <= diameter / 2 - 0.3 and @abs(position.z) <= diameter / 2 - 0.3;
    }

    fn gameModeOf(self: *PlayerStates, slot: usize) minecraft.GameMode {
        return self.records[slot].gamemode;
    }

    fn spawnWorld(self: *PlayerStates) u32 {
        return self.deps.vanilla_worlds.overworld;
    }

    fn spawnPoint(self: *PlayerStates, player: *const Player) !?Players.Rules.Spawn {
        const spawn = self.deps.spawn orelse return null;
        const selected = try spawn.select(player.world, self.config.gamemode, self.config.world_border);
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
                // A client that joined, respawned or changed world has forgotten the border.
                state.sending = if (state.life != player.life) .border else .health;
                state.life = player.life;
            }
            while (state.sending != .done) {
                switch (state.sending) {
                    .border => {
                        if (self.config.world_border) |diameter| {
                            if (!players.sendPacket(writeBorder, player.protocol, handle, .{diameter})) break;
                        }
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

    fn writeBorder(packet: wire_1_21_5.play.toClient.packet_initialize_world_border.Writer, diameter: f64) ![]u8 {
        const x = try packet.x(0);
        const z = try x.z(0);
        const old = try z.oldDiameter(diameter);
        const next = try old.newDiameter(diameter);
        const speed = try next.speed(0);
        const boundary = try speed.portalTeleportBoundary(29_999_984);
        const blocks = try boundary.warningBlocks(5);
        return (try blocks.warningTime(15)).finish();
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
    var players: Players = .{
        .deps = .{ .sessions = undefined, .packets = undefined, .input = undefined, .storage = try store.openSpace(Players.id), .worlds = dimensions, .record_workspaces = &workspaces },
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
        .deps = .{ .record_workspaces = &workspaces, .players = &players, .input = undefined, .packets = undefined, .storage = space, .worlds = dimensions, .vanilla_worlds = undefined },
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
    try std.testing.expect(player_states.setGameMode(&rows[1], .spectator));

    try players.onLifecycle(&departures);
    for (states) |state| try std.testing.expectEqual(@as(u128, 0), state.uuid);
    try players.onLifecycle(&joins);
    try std.testing.expectEqual(@as(f32, 7), states[0].health);
    try std.testing.expectEqual(@as(u4, 4), states[0].selected_slot);
    try std.testing.expectEqualDeep(points, states[0].experience);
    try std.testing.expectEqual(minecraft.GameMode.spectator, states[1].gamemode);
    try std.testing.expect(!rows[1].occluded);

    // A restart keeps what the last checkpoint wrote, as nobody left.
    states[0].health = 3;
    try player_states.checkpoint(space);
    rows = @splat(.{});
    states = @splat(.{});
    try players.onLifecycle(&joins);
    try std.testing.expectEqual(@as(f32, 3), states[0].health);

    var key: [16]u8 = undefined;
    std.mem.writeInt(u128, &key, 1, .little);
    var corrupt = states[0].encode();
    std.mem.writeInt(u32, corrupt[1..5], @bitCast(@as(f32, 25)), .little);
    try persistent_records.Table.init(space, resources).put(&key, &corrupt);
    rows = @splat(.{});
    states = @splat(.{});
    try std.testing.expectError(error.CorruptPlayer, players.onLifecycle(joins[0..1]));
}
