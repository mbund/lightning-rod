const std = @import("std");
const preallocated = @import("preallocated");
const config = @import("config.zig");
const chunk_stream = @import("chunk_view_tracker.zig");
const view = @import("view.zig");

const living_visibility_words = (config.value.max_living_entities + 63) / 64;
const item_visibility_words = (config.value.max_item_entities + 63) / 64;
const player_visibility_words = (config.connection_capacity + 63) / 64;

/// Per-recipient projection state owned by packet replication, not transport.
/// It records what a client has already been told so tick plugins can produce
/// the next exact packet delta.
pub const ClientProjection = struct {
    chunks: chunk_stream.Tracker = .{},
    view: view.PlayerView = .{},
    visible_players: []u64 = &.{},
    visible_living: []u64 = &.{},
    visible_items: []u64 = &.{},
    pending_item_metadata: []u64 = &.{},
    item_sync_pending: bool = false,
    chunks_per_tick: f32 = 9.0,
    chunk_batch_quota: f32 = 0.0,
    unacknowledged_chunk_batches: u8 = 0,
    maximum_unacknowledged_chunk_batches: u8 = 1,

    pub fn allocate(self: *ClientProjection, allocator: std.mem.Allocator) !void {
        self.* = .{};
        try self.chunks.allocate(allocator);
        try self.view.allocate(allocator);
        self.visible_players = try preallocated.alloc(u64, allocator, player_visibility_words);
        self.visible_living = try preallocated.alloc(u64, allocator, living_visibility_words);
        self.visible_items = try preallocated.alloc(u64, allocator, item_visibility_words);
        self.pending_item_metadata = try preallocated.alloc(u64, allocator, item_visibility_words);
    }

    pub fn reset(self: *ClientProjection) void {
        self.chunks.reset(.{ .x = 0, .z = 0 });
        self.view.reset();
        @memset(self.visible_players, 0);
        @memset(self.visible_living, 0);
        @memset(self.visible_items, 0);
        @memset(self.pending_item_metadata, 0);
        self.item_sync_pending = false;
        self.chunks_per_tick = 9.0;
        self.chunk_batch_quota = 0.0;
        self.unacknowledged_chunk_batches = 0;
        self.maximum_unacknowledged_chunk_batches = 1;
    }

    pub fn beginChunkBatch(self: *ClientProjection) u16 {
        if (self.unacknowledged_chunk_batches >=
            self.maximum_unacknowledged_chunk_batches) return 0;
        self.chunk_batch_quota = @min(
            self.chunk_batch_quota + self.chunks_per_tick,
            @max(1.0, self.chunks_per_tick),
        );
        if (self.chunk_batch_quota < 1.0) return 0;
        return @min(64, @as(u16, @intFromFloat(self.chunk_batch_quota)));
    }

    pub fn finishChunkBatch(self: *ClientProjection, chunk_count: u16) void {
        std.debug.assert(self.unacknowledged_chunk_batches <
            self.maximum_unacknowledged_chunk_batches);
        std.debug.assert(@as(f32, @floatFromInt(chunk_count)) <= self.chunk_batch_quota);
        self.chunk_batch_quota -= @floatFromInt(chunk_count);
        self.unacknowledged_chunk_batches += 1;
    }

    pub fn acknowledgeChunkBatch(self: *ClientProjection, chunks_per_tick: f32) void {
        if (self.unacknowledged_chunk_batches != 0)
            self.unacknowledged_chunk_batches -= 1;
        if (self.unacknowledged_chunk_batches == 0) {
            self.chunk_batch_quota = 1.0;
            self.maximum_unacknowledged_chunk_batches = 10;
        }
        self.chunks_per_tick = if (std.math.isNan(chunks_per_tick))
            1.0
        else
            std.math.clamp(chunks_per_tick, 0.01, 64.0);
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

    /// Avoid materializing a complete multi-megabyte default State in every
    /// executable that owns replication. Only one projection-sized default is
    /// needed and it is applied directly to already allocated storage.
    pub fn allocate(self: *State, allocator: std.mem.Allocator) !void {
        self.* = .{};
        self.clients = try preallocated.alloc(ClientProjection, allocator, config.connection_capacity);
        for (self.clients) |*client| try client.allocate(allocator);
    }

    pub fn reset(self: *State, slot: u16) void {
        self.clients[slot].reset();
    }
};

test "item projection distinguishes spawn visibility from pending metadata" {
    var projection: ClientProjection = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try projection.allocate(arena.allocator());
    projection.reset();
    projection.setItemVisible(47, true);
    projection.setItemMetadataPending(47, true);
    try std.testing.expect(projection.itemVisible(47));
    try std.testing.expect(projection.itemMetadataPending(47));

    projection.setItemVisible(47, false);
    try std.testing.expect(!projection.itemVisible(47));
    try std.testing.expect(!projection.itemMetadataPending(47));
}

test "chunk batch pacing is client driven and bounded" {
    var projection: ClientProjection = .{};
    try std.testing.expectEqual(@as(u16, 9), projection.beginChunkBatch());
    projection.finishChunkBatch(9);
    try std.testing.expectEqual(@as(u16, 0), projection.beginChunkBatch());

    projection.acknowledgeChunkBatch(1000.0);
    try std.testing.expectEqual(@as(u16, 64), projection.beginChunkBatch());
    projection.finishChunkBatch(64);
    projection.acknowledgeChunkBatch(0.01);
    try std.testing.expectEqual(@as(u16, 1), projection.beginChunkBatch());
}
