const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Players = @import("players.zig").Players;
const bit_sets = lightning_rod.system.bit_sets;
const sparse_sets = lightning_rod.system.sparse_sets;

pub const Row = struct {
    storage: sparse_sets.Row = .{},
    players: *Players = undefined,
    owner: ?usize = null,

    pub fn view(self: Row) bit_sets.Set {
        return self.storage.view();
    }

    fn reject(self: Row, observer: usize) void {
        const index = self.owner orelse observer;
        const handle = self.players.records[index].handle orelse return;
        const service = self.players.deps.sessions;
        if (service.canSend(handle, 0)) std.log.warn("event=audience_capacity_exceeded player={d}", .{index});
        service.disconnect(handle);
    }

    fn changed(self: Row, result: sparse_sets.Result) void {
        // Retaining the connection would leave its delivery state incomplete.
        const affected = result.changed orelse return;
        if (self.owner) |owner| {
            self.reject(owner);
            return;
        }
        var observers = affected.iterator();
        while (observers.next()) |observer| self.reject(observer);
    }

    pub fn clear(self: Row) void {
        self.storage.clear();
    }

    pub fn insert(self: Row, observer: usize) void {
        if (!self.storage.insert(observer)) self.reject(observer);
    }

    pub fn remove(self: Row, observer: usize) void {
        if (!self.storage.remove(observer)) self.reject(observer);
    }

    pub fn copy(self: Row, source: bit_sets.Set) void {
        self.changed(self.storage.apply(.copy, source, source));
    }

    pub fn unite(self: Row, a: bit_sets.Set, b: bit_sets.Set) void {
        self.changed(self.storage.apply(.unite, a, b));
    }

    pub fn intersect(self: Row, a: bit_sets.Set, b: bit_sets.Set) void {
        self.changed(self.storage.apply(.intersect, a, b));
    }

    pub fn subtract(self: Row, a: bit_sets.Set, b: bit_sets.Set) void {
        self.changed(self.storage.apply(.subtract, a, b));
    }

    pub fn difference(self: Row, a: bit_sets.Set, b: bit_sets.Set) void {
        self.changed(self.storage.apply(.difference, a, b));
    }
};

pub const Matrix = struct {
    pub const Orientation = union(enum) { recipients, subjects: usize };
    storage: sparse_sets.Matrix,
    players: *Players,
    orientation: Orientation,

    pub fn init(allocator: std.mem.Allocator, players: *Players, rows: usize, words: usize, orientation: Orientation) !Matrix {
        return .{ .storage = try sparse_sets.Matrix.init(allocator, rows, players.records.len, words), .players = players, .orientation = orientation };
    }

    pub fn row(self: Matrix, index: usize) Row {
        return .{ .storage = self.storage.row(index), .players = self.players, .owner = switch (self.orientation) {
            .recipients => null,
            .subjects => |stride| index / stride,
        } };
    }

    pub fn clear(self: Matrix) void {
        if (self.storage.dense) |matrix| @memset(matrix.words, 0) else for (0..self.storage.count) |index| self.storage.row(index).clear();
    }

    pub fn memoryBytes(self: Matrix) usize {
        return self.storage.memoryBytes();
    }
};
