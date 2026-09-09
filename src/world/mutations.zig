const blocks = @import("blocks.zig");
const geometry = @import("geometry.zig");
const world_identity = @import("identity.zig");
const registry = @import("registry_data");
const std = @import("std");
const test_generator = @import("../test_support/world_generator.zig");

pub const maximum_writes = 64;

pub const Transaction = struct {
    blocks: *blocks.Blocks,
    writes: [maximum_writes]blocks.MutationWrite = undefined,
    changed: [maximum_writes]bool = undefined,
    count: usize = 0,
    reserved: bool = false,
    committed: bool = false,

    pub fn init(blocks_value: *blocks.Blocks) Transaction {
        return .{ .blocks = blocks_value };
    }

    pub fn prepare(self: *Transaction, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) !void {
        if (self.reserved) return error.MutationReserved;
        for (self.writes[0..self.count]) |*mutation| {
            if (!mutation.world.eql(world) or !samePosition(mutation.pos, pos)) continue;
            mutation.block_state = block_state;
            return;
        }
        if (self.count == self.writes.len) return error.MutationCapacity;
        self.writes[self.count] = .{ .world = world, .pos = pos, .block_state = block_state };
        self.count += 1;
    }

    pub fn staged(self: *const Transaction, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        for (0..self.count) |offset| {
            const index = self.count - 1 - offset;
            const mutation = self.writes[index];
            if (mutation.world.eql(world) and samePosition(mutation.pos, pos)) return mutation.block_state;
        }
        return null;
    }

    pub fn blockAt(self: *const Transaction, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        return self.staged(world, pos) orelse self.blocks.blockAtIfMaterialized(world, pos);
    }

    pub fn reserve(self: *Transaction) !void {
        if (self.committed) return error.MutationCommitted;
        if (self.reserved) return;
        try self.blocks.prepareBlockWrites(self.writes[0..self.count]);
        self.reserved = true;
    }

    pub fn commit(self: *Transaction) !usize {
        if (self.committed) return error.MutationCommitted;
        try self.reserve();
        const count = self.blocks.commitPreparedBlockWrites(self.writes[0..self.count], self.changed[0..self.count]);
        self.committed = true;
        return count;
    }

    pub fn wasChanged(self: *const Transaction, index: usize) bool {
        return index < self.count and self.committed and self.changed[index];
    }

    pub fn writeAt(self: *const Transaction, index: usize) blocks.MutationWrite {
        return self.writes[index];
    }
};

fn samePosition(a: geometry.BlockPos, b: geometry.BlockPos) bool {
    return a.x == b.x and a.y == b.y and a.z == b.z;
}

test "reservation rejects a whole mutation set before any block changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const block_world = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 1,
        .maximum_block_mutations = 16,
    });
    try generator.init(arena.allocator(), 0);
    generator.bind(block_world);
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    const lower = geometry.BlockPos{ .x = 0, .y = 64, .z = 0 };
    const upper = geometry.BlockPos{ .x = 0, .y = 80, .z = 0 };
    block_world.ensureChunkAt(world, lower.x, lower.z, 0);
    const previous_lower = block_world.blockAt(world, lower);
    const previous_upper = block_world.blockAt(world, upper);

    var transaction = Transaction.init(block_world);
    try transaction.prepare(world, lower, registry.block_air_default_state);
    try transaction.prepare(world, upper, registry.block_stone_default_state);
    try std.testing.expectError(error.WorldSectionCapacity, transaction.reserve());
    try std.testing.expectEqual(previous_lower, block_world.blockAt(world, lower));
    try std.testing.expectEqual(previous_upper, block_world.blockAt(world, upper));
}

test "overlay keeps the final write and commits it once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const block_world = try blocks.Blocks.init(arena.allocator(), test_generator.block_configuration);
    try generator.init(arena.allocator(), 0);
    generator.bind(block_world);
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    const position = geometry.BlockPos{ .x = 0, .y = 80, .z = 0 };
    block_world.ensureChunkAt(world, position.x, position.z, 0);

    var transaction = Transaction.init(block_world);
    try transaction.prepare(world, position, registry.block_dirt_default_state);
    try transaction.prepare(world, position, registry.block_stone_default_state);
    try std.testing.expectEqual(registry.block_stone_default_state, transaction.blockAt(world, position).?);
    try std.testing.expectEqual(@as(usize, 1), try transaction.commit());
    try std.testing.expect(transaction.wasChanged(0));
    try std.testing.expectEqual(registry.block_stone_default_state, block_world.blockAt(world, position));
}
