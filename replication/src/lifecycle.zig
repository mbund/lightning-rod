//! What each observer's client was told about each subject player: whether it knows the player
//! (it has the player's info entry), whether the entry is listed, whether it has the player's
//! current chat key, and the game mode it was shown. One bit per pair in dense matrices by player
//! slot, allocated once: nothing fills up, so nothing ever has to give way.
//!
//! A slot always means its current occupant. When an observer leaves, its column is cleared at
//! once, as that client is gone. A departed subject's row drains as observers are told it is
//! gone, and its slot is not reused until the row is empty, so no pair ever speaks of an older
//! occupant.

const std = @import("std");
const bit_sets = @import("lightning_rod").system.bit_sets;
const minecraft = @import("minecraft_model");
const assert = std.debug.assert;

pub const Lifecycle = struct {
    pub const State = struct {
        known: bool = false,
        listed: bool = false,
        /// Whether the observer has the subject's chat key as it stands.
        chat: bool = false,
        /// The game mode the observer was shown, while it knows the subject.
        gamemode: ?minecraft.GameMode = null,
        /// Kept by replication beside the table, in each observer's spawned set.
        spawned: bool = false,
    };

    /// Rows are subjects, bits observers.
    known: bit_sets.Matrix,
    listed: bit_sets.Matrix,
    chat: bit_sets.Matrix,
    /// Whether a game mode was shown, and its two bits.
    moded: bit_sets.Matrix,
    mode: [2]bit_sets.Matrix,
    scratch: []State,
    working: ?usize = null,
    selected: bit_sets.Set = undefined,

    /// The bytes its rows take.
    pub fn memoryBytes(self: *const Lifecycle) usize {
        var words = self.known.words.len + self.listed.words.len + self.chat.words.len + self.moded.words.len;
        for (self.mode) |matrix| words += matrix.words.len;
        return words * @sizeOf(usize);
    }

    pub fn init(allocator: std.mem.Allocator, players: usize) !Lifecycle {
        assert(players > 0);
        return .{
            .known = try .init(allocator, players, players),
            .listed = try .init(allocator, players, players),
            .chat = try .init(allocator, players, players),
            .moded = try .init(allocator, players, players),
            .mode = .{ try .init(allocator, players, players), try .init(allocator, players, players) },
            .scratch = try allocator.alloc(State, players),
        };
    }

    pub fn get(self: *const Lifecycle, subject: usize, observer: usize) State {
        if (self.working == subject and self.selected.contains(observer)) return self.scratch[observer];
        if (!self.known.row(subject).view().contains(observer)) return .{};
        const low: u2 = @intFromBool(self.mode[0].row(subject).view().contains(observer));
        const high: u2 = @intFromBool(self.mode[1].row(subject).view().contains(observer));
        return .{
            .known = true,
            .listed = self.listed.row(subject).view().contains(observer),
            .chat = self.chat.row(subject).view().contains(observer),
            .gamemode = if (self.moded.row(subject).view().contains(observer)) @fromBackingInt(@intCast(@as(i8, high << 1 | low))) else null,
        };
    }

    /// Borrows the selection until commit. Never fails: every pair has its bits.
    pub fn begin(self: *Lifecycle, subject: usize, selected: bit_sets.Set) void {
        assert(self.working == null and selected.capacity == self.scratch.len);
        var observers = selected.iterator();
        while (observers.next()) |observer| self.scratch[observer] = self.get(subject, observer);
        self.selected = selected;
        self.working = subject;
    }

    pub fn edit(self: *Lifecycle, observer: usize) *State {
        assert(self.working != null and self.selected.contains(observer));
        return &self.scratch[observer];
    }

    pub fn commit(self: *Lifecycle) void {
        const subject = self.working.?;
        var observers = self.selected.iterator();
        while (observers.next()) |observer| {
            const value = self.scratch[observer];
            assert(value.known or (!value.listed and !value.chat));
            const mode: u2 = if (value.gamemode) |gamemode| @intCast(@backingInt(gamemode)) else 0;
            set(self.known.row(subject), observer, value.known);
            set(self.listed.row(subject), observer, value.listed);
            set(self.chat.row(subject), observer, value.chat);
            set(self.moded.row(subject), observer, value.known and value.gamemode != null);
            set(self.mode[0].row(subject), observer, value.known and mode & 1 != 0);
            set(self.mode[1].row(subject), observer, value.known and mode & 2 != 0);
        }
        self.working = null;
    }

    fn set(row: bit_sets.Row, index: usize, value: bool) void {
        if (value) row.insert(index) else row.remove(index);
    }

    /// The subject's chat key changed: every observer needs it again.
    pub fn chatChanged(self: *Lifecycle, subject: usize) void {
        assert(self.working == null);
        self.chat.row(subject).clear();
    }

    /// An observer's client is gone: nothing it was told counts any more.
    pub fn forget(self: *Lifecycle, observer: usize) void {
        assert(self.working == null);
        for (0..self.scratch.len) |subject| {
            self.known.row(subject).remove(observer);
            self.listed.row(subject).remove(observer);
            self.chat.row(subject).remove(observer);
            self.moded.row(subject).remove(observer);
            self.mode[0].row(subject).remove(observer);
            self.mode[1].row(subject).remove(observer);
        }
    }

    /// The observers that still know the subject: while any do, its slot is owed to it.
    pub fn knownBy(self: *const Lifecycle, subject: usize) bit_sets.Set {
        return self.known.row(subject).view();
    }

    /// Whether no observer knows the subject, so its slot may take a new player.
    pub fn drained(self: *const Lifecycle, subject: usize) bool {
        assert(self.working == null);
        const empty = !self.known.row(subject).view().any();
        if (empty) assert(!self.listed.row(subject).view().any() and !self.chat.row(subject).view().any() and !self.moded.row(subject).view().any() and
            !self.mode[0].row(subject).view().any() and !self.mode[1].row(subject).view().any());
        return empty;
    }
};

test "lifecycle pairs keep what each observer was told, and an observer that leaves is forgotten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = try Lifecycle.init(arena.allocator(), 4);
    const shown: Lifecycle.State = .{ .known = true, .listed = true, .chat = true, .gamemode = .spectator };
    const words = [_]usize{0b0111};
    table.begin(0, .{ .words = &words, .capacity = 4 });
    table.edit(0).* = shown;
    table.edit(1).* = .{ .known = true, .gamemode = .survival };
    table.commit();
    try std.testing.expectEqual(shown, table.get(0, 0));
    try std.testing.expectEqual(Lifecycle.State{ .known = true, .gamemode = .survival }, table.get(0, 1));
    try std.testing.expectEqual(Lifecycle.State{}, table.get(0, 2));
    try std.testing.expect(!table.drained(0));
    table.chatChanged(0);
    try std.testing.expect(!table.get(0, 0).chat);
    table.forget(0);
    try std.testing.expectEqual(Lifecycle.State{}, table.get(0, 0));
    table.begin(0, .{ .words = &words, .capacity = 4 });
    table.edit(1).* = .{};
    table.commit();
    try std.testing.expect(table.drained(0));
}

test "every pair of a crowd fits at once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const players = 300;
    var table = try Lifecycle.init(arena.allocator(), players);
    const words = try arena.allocator().alloc(usize, (players + 63) / 64);
    @memset(words, std.math.maxInt(usize));
    words[words.len - 1] = (@as(usize, 1) << (players % 64)) - 1;
    const everyone: bit_sets.Set = .{ .words = words, .capacity = players };
    for (0..players) |subject| {
        table.begin(subject, everyone);
        for (0..players) |observer| table.edit(observer).* = .{ .known = true, .listed = true, .gamemode = .creative };
        table.commit();
    }
    for (0..players) |subject| try std.testing.expectEqual(@as(usize, players), table.knownBy(subject).count());
}
