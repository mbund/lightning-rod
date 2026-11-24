//! What changed of every player since the last tick, worked out once for everything that
//! replicates to players: who reconnected, respawned, changed world or became ready or stopped
//! being, who moved and from where, and whose view distance changed. Each list is good for the
//! tick it was made in.

const std = @import("std");
const Players = @import("players").players.Players;
const Player = Players.Player;
const assert = std.debug.assert;

pub const PlayerChanges = struct {
    /// A player as the last tick left it.
    pub const Snapshot = struct {
        generation: u32 = 0,
        life: u32 = 0,
        world: u32 = 0,
        ready: bool = false,
        /// In spectator mode, which decides which players it sees.
        spectator: bool = false,
        x: f64 = 0,
        z: f64 = 0,
        /// The view distance in blocks, which caps what the player is shown.
        reach: f64 = 0,
    };

    pub const Move = struct { player: u16, from: [2]f64, to: [2]f64 };
    pub const View = struct { player: u16, from: f64, to: f64 };
    /// A player that reconnected, respawned, changed world, became ready or stopped being, or
    /// went in or out of spectator mode.
    /// `was` is how it stood before, `now` how it stands; `forgot` is whether its client forgot
    /// what it was shown, as it does all but for a change of readiness alone.
    pub const Reset = struct { player: u16, was: Snapshot, now: Snapshot, forgot: bool };

    snapshots: []Snapshot,
    resets: []Reset,
    reset_count: usize = 0,
    moves: []Move,
    move_count: usize = 0,
    views: []View,
    view_count: usize = 0,
    /// How far, at most, any player's circle edge has come towards anything since the server
    /// started: the farthest any player moved each tick and any view distance shrank or grew,
    /// summed. A distance to the nearest edge measured at one drift is good, less what the
    /// drift grew since.
    drift: f64 = 0,
    /// Rises whenever a player arrives anywhere: a new circle, which no distance measured before
    /// knew of.
    epoch: u64 = 0,
    /// Whether spectator mode is read: a player's game mode is asked for, and costs a call.
    modes: bool,

    pub fn init(allocator: std.mem.Allocator, players: usize, modes: bool) !PlayerChanges {
        const snapshots = try allocator.alloc(Snapshot, players);
        @memset(snapshots, .{});
        return .{
            .snapshots = snapshots,
            .resets = try allocator.alloc(Reset, players),
            .moves = try allocator.alloc(Move, players),
            .views = try allocator.alloc(View, players),
            .modes = modes,
        };
    }

    pub fn snapshotOf(players: *const Players, player: Player, index: usize, modes: bool) Snapshot {
        const handle = player.handle orelse return .{};
        return .{
            .generation = handle.generation,
            .life = player.life,
            .world = player.world,
            .ready = player.stage == .ready,
            .spectator = modes and players.gameMode(index) == .spectator,
            .x = player.position.x,
            .z = player.position.z,
            .reach = @floatFromInt(players.viewDistanceOf(player) * 16),
        };
    }

    /// No changes, for a pass that does not hear the players again.
    pub fn clearLists(self: *PlayerChanges) void {
        self.reset_count = 0;
        self.move_count = 0;
        self.view_count = 0;
    }

    /// Compares every connected player, and every one that was, with the last tick.
    pub fn update(self: *PlayerChanges, players: *const Players) void {
        self.reset_count = 0;
        self.move_count = 0;
        self.view_count = 0;
        var farthest: f64 = 0;
        var arrived = false;
        for (players.records, self.snapshots, 0..) |player, *snapshot, index| {
            const now = snapshotOf(players, player, index, self.modes);
            const was = snapshot.*;
            if (was.generation == 0 and now.generation == 0) continue;
            snapshot.* = now;
            if (was.generation != now.generation or was.life != now.life or was.world != now.world or was.ready != now.ready or was.spectator != now.spectator) {
                if (!was.ready and !now.ready) continue;
                const forgot = was.generation != now.generation or was.life != now.life or was.world != now.world;
                self.resets[self.reset_count] = .{ .player = @intCast(index), .was = was, .now = now, .forgot = forgot };
                self.reset_count += 1;
                if (now.ready) arrived = true;
                continue;
            }
            if (!now.ready) continue;
            if (was.x != now.x or was.z != now.z) {
                self.moves[self.move_count] = .{ .player = @intCast(index), .from = .{ was.x, was.z }, .to = .{ now.x, now.z } };
                self.move_count += 1;
                farthest = @max(farthest, @sqrt((now.x - was.x) * (now.x - was.x) + (now.z - was.z) * (now.z - was.z)));
            }
            if (was.reach != now.reach) {
                self.views[self.view_count] = .{ .player = @intCast(index), .from = was.reach, .to = now.reach };
                self.view_count += 1;
                farthest = @max(farthest, @abs(now.reach - was.reach));
            }
        }
        self.drift += farthest;
        if (arrived) self.epoch += 1;
    }

    pub fn resetList(self: *const PlayerChanges) []const Reset {
        return self.resets[0..self.reset_count];
    }

    pub fn moveList(self: *const PlayerChanges) []const Move {
        return self.moves[0..self.move_count];
    }

    pub fn viewList(self: *const PlayerChanges) []const View {
        return self.views[0..self.view_count];
    }
};
