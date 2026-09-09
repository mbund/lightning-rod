const std = @import("std");
const preallocated = @import("preallocated");
const view = @import("view.zig");

pub const Configuration = struct {
    maximum_clients: usize,
    maximum_players: usize,
    maximum_living: usize,
    maximum_items: usize,
    view: view.Configuration = .{},

    pub fn validate(self: Configuration) !void {
        if (self.maximum_clients == 0 or self.maximum_players == 0 or self.maximum_living == 0 or self.maximum_items == 0) return error.InvalidReplicationCapacity;
        try self.view.validate();
    }
};

pub const ClientProjection = struct {
    view: view.PlayerView = .{},
    visible_players: []u64 = &.{},
    visible_living: []u64 = &.{},
    visible_items: []u64 = &.{},
    pending_item_metadata: []u64 = &.{},
    item_sync_pending: bool = false,

    pub fn allocate(
        self: *ClientProjection,
        allocator: std.mem.Allocator,
        configuration: Configuration,
    ) !void {
        self.* = .{};
        try self.view.allocate(allocator, configuration.view);
        self.visible_players = try preallocated.alloc(u64, allocator, wordsFor(configuration.maximum_players));
        self.visible_living = try preallocated.alloc(u64, allocator, wordsFor(configuration.maximum_living));
        self.visible_items = try preallocated.alloc(u64, allocator, wordsFor(configuration.maximum_items));
        self.pending_item_metadata = try preallocated.alloc(u64, allocator, wordsFor(configuration.maximum_items));
    }

    pub fn reset(self: *ClientProjection) void {
        self.view.reset();
        @memset(self.visible_players, 0);
        @memset(self.visible_living, 0);
        @memset(self.visible_items, 0);
        @memset(self.pending_item_metadata, 0);
        self.item_sync_pending = false;
    }

    pub inline fn playerVisible(self: *const ClientProjection, slot: u16) bool {
        return bitIsSet(self.visible_players, slot);
    }

    pub inline fn setPlayerVisible(self: *ClientProjection, slot: u16, visible: bool) void {
        setBit(self.visible_players, slot, visible);
    }

    pub inline fn itemVisible(self: *const ClientProjection, index: u16) bool {
        return bitIsSet(self.visible_items, index);
    }

    pub inline fn setItemVisible(self: *ClientProjection, index: u16, visible: bool) void {
        setBit(self.visible_items, index, visible);
        if (!visible) setBit(self.pending_item_metadata, index, false);
    }

    pub inline fn itemMetadataPending(self: *const ClientProjection, index: u16) bool {
        return bitIsSet(self.pending_item_metadata, index);
    }

    pub inline fn setItemMetadataPending(self: *ClientProjection, index: u16, pending: bool) void {
        setBit(self.pending_item_metadata, index, pending);
    }
};

inline fn bitIsSet(words: []const u64, index: u16) bool {
    const word = index >> 6;
    const mask = @as(u64, 1) << @intCast(index & 63);
    return words[word] & mask != 0;
}

inline fn wordsFor(capacity: usize) usize {
    return std.math.divCeil(usize, capacity, 64) catch unreachable;
}

inline fn setBit(words: []u64, index: u16, value: bool) void {
    const word = index >> 6;
    const mask = @as(u64, 1) << @intCast(index & 63);
    if (value)
        words[word] |= mask
    else
        words[word] &= ~mask;
}

pub const State = struct {
    clients: []ClientProjection = &.{},

    pub fn allocate(self: *State, allocator: std.mem.Allocator, configuration: Configuration) !void {
        try configuration.validate();
        self.* = .{};
        self.clients = try preallocated.alloc(ClientProjection, allocator, configuration.maximum_clients);
        for (self.clients) |*client|
            try client.allocate(allocator, configuration);
    }

    pub fn reset(self: *State, slot: u16) void {
        self.clients[slot].reset();
    }
};

test "item projection distinguishes spawn visibility from pending metadata" {
    var projection: ClientProjection = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try projection.allocate(arena.allocator(), .{
        .maximum_clients = 1,
        .maximum_players = 64,
        .maximum_living = 64,
        .maximum_items = 64,
    });
    projection.reset();
    projection.setItemVisible(47, true);
    projection.setItemMetadataPending(47, true);
    try std.testing.expect(projection.itemVisible(47));
    try std.testing.expect(projection.itemMetadataPending(47));

    projection.setItemVisible(47, false);
    try std.testing.expect(!projection.itemVisible(47));
    try std.testing.expect(!projection.itemMetadataPending(47));
}
