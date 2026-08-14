const block_store = @import("world/blocks.zig");
const geometry = @import("world/geometry.zig");
const std = @import("std");
const registry = @import("registry_data");
const preallocated = @import("preallocated");
const config = @import("config.zig").value;
const world_identity = @import("world/identity.zig");

pub const ChunkProjection = enum(u8) { canonical, personalized };

pub const ProjectionIdentity = extern struct {
    source: u64 = 0,
    revision: u64 = 0,

    pub inline fn valid(self: ProjectionIdentity) bool {
        return self.source != 0;
    }
};

const Overlay = struct {
    active: bool = false,
    pos: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    state: i32 = registry.block_air_default_state,
};

const OverlayChunk = struct {
    active: bool = false,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    count: u16 = 0,
};

pub const PlayerView = struct {
    overlays: []Overlay = &.{},
    overlay_chunks: []OverlayChunk = &.{},
    overlay_count: usize = 0,

    pub fn allocate(self: *PlayerView, allocator: std.mem.Allocator) !void {
        self.* = .{};
        self.overlays = try preallocated.alloc(
            Overlay,
            allocator,
            config.max_player_block_overlays,
        );
        self.overlay_chunks = try preallocated.alloc(
            OverlayChunk,
            allocator,
            config.max_player_block_overlays,
        );
    }

    pub fn reset(self: *PlayerView) void {
        @memset(self.overlays, .{});
        @memset(self.overlay_chunks, .{});
        self.overlay_count = 0;
    }

    pub fn setOverlay(
        self: *PlayerView,
        pos: geometry.BlockPos,
        state: i32,
    ) !void {
        if (self.findOverlay(pos)) |index| {
            self.overlays[index].state = state;
            return;
        }
        if (self.overlay_count >= self.overlays.len / 2)
            return error.PlayerOverlayCapacity;
        var probe = blockHash(pos);
        for (0..self.overlays.len) |_| {
            const index = probe & (self.overlays.len - 1);
            if (self.overlays[index].active) {
                probe += 1;
                continue;
            }
            self.overlays[index] = .{
                .active = true,
                .pos = pos,
                .state = state,
            };
            self.overlay_count += 1;
            try self.incrementChunk(geometry.chunkForBlock(pos));
            return;
        }
        return error.PlayerOverlayCapacity;
    }

    pub fn removeOverlay(self: *PlayerView, pos: geometry.BlockPos) bool {
        const index = self.findOverlay(pos) orelse return false;
        const chunk = geometry.chunkForBlock(pos);
        backshiftDelete(Overlay, self.overlays, index, overlayIdeal);
        self.overlay_count -= 1;
        self.decrementChunk(chunk);
        return true;
    }

    pub inline fn blockAt(
        self: *const PlayerView,
        blocks: *const block_store.Blocks,
        world: world_identity.Handle,
        pos: geometry.BlockPos,
    ) i32 {
        return self.blockOverlay(pos) orelse blocks.blockAt(world, pos);
    }

    pub inline fn blockAtUnrestricted(
        self: *const PlayerView,
        blocks: *const block_store.Blocks,
        world: world_identity.Handle,
        pos: geometry.BlockPos,
    ) i32 {
        return self.blockAt(blocks, world, pos);
    }

    pub inline fn requiresPersonalizedChunk(
        self: *const PlayerView,
        chunk: geometry.ChunkPos,
    ) bool {
        return self.chunkHasOverlays(chunk);
    }

    pub fn chunkProjection(
        self: *const PlayerView,
        chunk: geometry.ChunkPos,
    ) ChunkProjection {
        return self.chunkProjectionUnrestricted(chunk);
    }

    pub fn chunkProjectionUnrestricted(
        self: *const PlayerView,
        chunk: geometry.ChunkPos,
    ) ChunkProjection {
        return if (self.chunkHasOverlays(chunk)) .personalized else .canonical;
    }

    pub inline fn chunkHasOverlays(
        self: *const PlayerView,
        chunk: geometry.ChunkPos,
    ) bool {
        return self.findOverlayChunk(chunk) != null;
    }

    pub fn applySectionOverlays(
        self: *const PlayerView,
        chunk: geometry.ChunkPos,
        section: usize,
        states: *[block_store.blocks_per_section]i32,
    ) void {
        if (!self.chunkHasOverlays(chunk)) return;
        for (self.overlays) |overlay| {
            if (!overlay.active or
                !geometry.sameChunk(geometry.chunkForBlock(overlay.pos), chunk))
                continue;
            const overlay_section =
                block_store.sectionIndexForY(overlay.pos.y) orelse continue;
            if (overlay_section != section) continue;
            const x: usize = @intCast(overlay.pos.x & 15);
            const y: usize = @intCast(
                (@as(i32, overlay.pos.y) - config.world_min_y) & 15,
            );
            const z: usize = @intCast(overlay.pos.z & 15);
            states[x | (z << 4) | (y << 8)] = overlay.state;
        }
    }

    fn blockOverlay(self: *const PlayerView, pos: geometry.BlockPos) ?i32 {
        return self.overlays[self.findOverlay(pos) orelse return null].state;
    }

    fn findOverlay(self: *const PlayerView, pos: geometry.BlockPos) ?usize {
        var probe = blockHash(pos);
        for (0..self.overlays.len) |_| {
            const index = probe & (self.overlays.len - 1);
            const value = self.overlays[index];
            if (!value.active) return null;
            if (value.pos.x == pos.x and value.pos.y == pos.y and
                value.pos.z == pos.z)
                return index;
            probe += 1;
        }
        return null;
    }

    fn incrementChunk(self: *PlayerView, chunk: geometry.ChunkPos) !void {
        if (self.findOverlayChunk(chunk)) |index| {
            self.overlay_chunks[index].count += 1;
            return;
        }
        var probe = chunkHash(chunk);
        for (0..self.overlay_chunks.len) |_| {
            const index = probe & (self.overlay_chunks.len - 1);
            if (self.overlay_chunks[index].active) {
                probe += 1;
                continue;
            }
            self.overlay_chunks[index] = .{
                .active = true,
                .chunk = chunk,
                .count = 1,
            };
            return;
        }
        return error.PlayerOverlayCapacity;
    }

    fn decrementChunk(self: *PlayerView, chunk: geometry.ChunkPos) void {
        const index = self.findOverlayChunk(chunk).?;
        self.overlay_chunks[index].count -= 1;
        if (self.overlay_chunks[index].count == 0)
            backshiftDelete(
                OverlayChunk,
                self.overlay_chunks,
                index,
                overlayChunkIdeal,
            );
    }

    fn findOverlayChunk(
        self: *const PlayerView,
        chunk: geometry.ChunkPos,
    ) ?usize {
        var probe = chunkHash(chunk);
        for (0..self.overlay_chunks.len) |_| {
            const index = probe & (self.overlay_chunks.len - 1);
            const value = self.overlay_chunks[index];
            if (!value.active) return null;
            if (geometry.sameChunk(value.chunk, chunk)) return index;
            probe += 1;
        }
        return null;
    }
};

fn backshiftDelete(
    comptime Entry: type,
    table: []Entry,
    deleted: usize,
    comptime ideal: fn (Entry, usize) usize,
) void {
    const mask = table.len - 1;
    var hole = deleted;
    table[hole] = .{};
    var scan = (hole + 1) & mask;
    for (0..table.len) |_| {
        if (!table[scan].active) return;
        const home = ideal(table[scan], mask);
        if (((hole -% home) & mask) < ((scan -% home) & mask)) {
            table[hole] = table[scan];
            table[scan] = .{};
            hole = scan;
        }
        scan = (scan + 1) & mask;
    }
    unreachable;
}

fn overlayIdeal(value: Overlay, mask: usize) usize {
    return blockHash(value.pos) & mask;
}

fn overlayChunkIdeal(value: OverlayChunk, mask: usize) usize {
    return chunkHash(value.chunk) & mask;
}

fn blockHash(pos: geometry.BlockPos) usize {
    var result = chunkHash(geometry.chunkForBlock(pos));
    result *%= 0x9e37_79b9;
    result ^= @as(u16, @bitCast(pos.y));
    return result;
}

fn chunkHash(pos: geometry.ChunkPos) usize {
    var result: u64 = @as(u32, @bitCast(pos.x));
    result *%= 0xbf58_476d_1ce4_e5b9;
    result ^= @as(u32, @bitCast(pos.z));
    result *%= 0x94d0_49bb_1331_11eb;
    return @intCast(result);
}
