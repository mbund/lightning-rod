const block_store = @import("world/blocks.zig");
const geometry = @import("world/geometry.zig");
const std = @import("std");
const registry = @import("registry_data");
const test_state = @import("test_support/state.zig");
const diagnostics = @import("diagnostics.zig");
const world_identity = @import("world/identity.zig");
const Packets = @import("packet_writer.zig").Packets;
const tick_host = @import("tick_host.zig");

pub const max_batch_changes = 64;

pub const Writer = struct {
    blocks: *block_store.Blocks,
    outputs: *Packets,

    const Self = @This();

    pub inline fn init(block_world: *block_store.Blocks, outputs: *Packets) Self {
        return .{ .blocks = block_world, .outputs = outputs };
    }

    pub inline fn set(self: Self, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) !bool {
        if (self.blocks.residentChunk(world, geometry.chunkForBlock(pos)) == null)
            return error.ChunkNotResident;
        const changed = try self.blocks.setBlock(world, pos, block_state);
        if (changed) self.emit(world, pos, block_state);
        return changed;
    }

    pub inline fn beginBatch(self: Self) Batch {
        return Batch.init(self);
    }

    inline fn emit(self: Self, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) void {
        self.outputs.block_changed(.{ .world = world, .pos = pos, .block_state = block_state });
    }
};

pub const Batch = struct {
    writer: Writer,
    changes: [max_batch_changes]Change = undefined,
    len: usize = 0,

    const Self = @This();
    const Change = struct {
        world: world_identity.Handle,
        pos: geometry.BlockPos,
        block_state: i32,
        previous_state: i32 = undefined,
        applied: bool = false,
    };

    fn init(writer: Writer) Self {
        return .{ .writer = writer };
    }

    pub inline fn set(self: *Self, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) error{BlockBatchFull}!void {
        for (self.changes[0..self.len]) |*change| {
            if (change.world.eql(world) and samePosition(change.pos, pos)) {
                change.block_state = block_state;
                return;
            }
        }
        if (self.len == self.changes.len) return error.BlockBatchFull;
        self.changes[self.len] = .{ .world = world, .pos = pos, .block_state = block_state };
        self.len += 1;
    }

    pub fn finish(self: *Self) !usize {
        var applied_count: usize = 0;
        for (self.changes[0..self.len]) |*change| {
            if (self.writer.blocks.residentChunk(change.world, geometry.chunkForBlock(change.pos)) == null) {
                self.rollback();
                return error.ChunkNotResident;
            }
            change.previous_state = self.writer.blocks.blockAt(change.world, change.pos);
            change.applied = self.writer.blocks.setBlock(change.world, change.pos, change.block_state) catch |err| {
                self.rollback();
                return err;
            };
            applied_count += @intFromBool(change.applied);
        }
        for (self.changes[0..self.len]) |change| {
            if (change.applied) self.writer.emit(change.world, change.pos, change.block_state);
        }
        self.len = 0;
        return applied_count;
    }

    fn rollback(self: *Self) void {
        var index = self.len;
        while (index != 0) {
            index -= 1;
            const change = &self.changes[index];
            if (!change.applied) continue;
            const restored = self.writer.blocks.setBlock(change.world, change.pos, change.previous_state) catch |err|
                diagnostics.panic("block batch rollback failed (x, y, z, error)", &.{ diagnostics.integer(change.pos.x), diagnostics.integer(change.pos.y), diagnostics.integer(change.pos.z), diagnostics.text(@errorName(err)) });
            if (!restored)
                diagnostics.panic("block batch rollback did not restore block (x, y, z)", &.{ diagnostics.integer(change.pos.x), diagnostics.integer(change.pos.y), diagnostics.integer(change.pos.z) });
            change.applied = false;
        }
        self.len = 0;
    }
};

inline fn samePosition(a: geometry.BlockPos, b: geometry.BlockPos) bool {
    return a.x == b.x and a.y == b.y and a.z == b.z;
}

test "writer couples authoritative state and block output" {
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 11);
    defer simulation.deinit();

    var host: tick_host.Host = undefined;
    var output = Packets.init(&host);
    const blocks = Writer.init(simulation.blocks, &output);
    const pos = geometry.BlockPos{ .x = 1, .y = 100, .z = 2 };
    simulation.blocks.ensureChunkAt(simulation.world, pos.x, pos.z, simulation.clock.tick);
    const previous = simulation.blocks.blockAt(simulation.world, pos);
    const replacement = if (previous == registry.block_air_default_state) registry.block_stone_default_state else registry.block_air_default_state;

    try std.testing.expect(try blocks.set(simulation.world, pos, replacement));
    try std.testing.expectEqual(replacement, simulation.blocks.blockAt(simulation.world, pos));
    try std.testing.expectEqual(@as(usize, 1), output.pending_block_change_count);
    try std.testing.expect(samePosition(pos, output.pending_block_changes[0].pos));
    try std.testing.expectEqual(replacement, output.pending_block_changes[0].block_state);
    try std.testing.expect(!(try blocks.set(simulation.world, pos, replacement)));
    try std.testing.expectEqual(@as(usize, 1), output.pending_block_change_count);
}

test "batch coalesces positions and emits committed changes in order" {
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 12);
    defer simulation.deinit();

    var host: tick_host.Host = undefined;
    var output = Packets.init(&host);
    const blocks = Writer.init(simulation.blocks, &output);
    var batch = blocks.beginBatch();
    const first = geometry.BlockPos{ .x = 3, .y = 101, .z = 4 };
    const second = geometry.BlockPos{ .x = 4, .y = 101, .z = 4 };
    simulation.blocks.ensureChunkAt(simulation.world, first.x, first.z, simulation.clock.tick);
    const first_previous = simulation.blocks.blockAt(simulation.world, first);
    const second_previous = simulation.blocks.blockAt(simulation.world, second);
    const first_state = if (first_previous == registry.block_air_default_state) registry.block_stone_default_state else registry.block_air_default_state;
    const second_state = if (second_previous == registry.block_air_default_state) registry.block_dirt_default_state else registry.block_air_default_state;

    try batch.set(simulation.world, first, registry.block_dirt_default_state);
    try batch.set(simulation.world, second, second_state);
    try batch.set(simulation.world, first, first_state);
    try std.testing.expectEqual(@as(usize, 2), try batch.finish());
    try std.testing.expectEqual(@as(usize, 2), output.pending_block_change_count);
    try std.testing.expect(samePosition(first, output.pending_block_changes[0].pos));
    try std.testing.expect(samePosition(second, output.pending_block_changes[1].pos));
    try std.testing.expectEqual(first_state, simulation.blocks.blockAt(simulation.world, first));
    try std.testing.expectEqual(second_state, simulation.blocks.blockAt(simulation.world, second));
}
