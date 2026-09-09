const block_store = @import("world/blocks.zig");
const geometry = @import("world/geometry.zig");
const mutations = @import("world/mutations.zig");
const world_identity = @import("world/identity.zig");
const Packets = @import("packet_writer.zig").Packets;

pub const max_batch_changes = mutations.maximum_writes;

pub const Writer = struct {
    blocks: *block_store.Blocks,
    outputs: *Packets,

    const Self = @This();

    pub inline fn init(block_world: *block_store.Blocks, outputs: *Packets) Self {
        return .{ .blocks = block_world, .outputs = outputs };
    }

    pub inline fn set(self: Self, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) !bool {
        var batch = self.beginBatch();
        try batch.set(world, pos, block_state);
        return (try batch.finish()) != 0;
    }

    pub inline fn beginBatch(self: Self) Batch {
        return Batch.init(self);
    }

};

pub const Batch = struct {
    writer: Writer,
    transaction: mutations.Transaction,

    const Self = @This();
    fn init(writer: Writer) Self {
        return .{ .writer = writer, .transaction = .init(writer.blocks) };
    }

    pub inline fn set(self: *Self, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) !void {
        try self.transaction.prepare(world, pos, block_state);
    }

    pub fn finish(self: *Self) !usize {
        const changed = try self.transaction.commit();
        var changes: [mutations.maximum_writes]@import("packet_args.zig").BlockChanged = undefined;
        var change_count: usize = 0;
        for (0..self.transaction.count) |index| {
            if (!self.transaction.wasChanged(index)) continue;
            const mutation = self.transaction.writeAt(index);
            changes[change_count] = .{ .world = mutation.world, .pos = mutation.pos, .block_state = mutation.block_state };
            change_count += 1;
        }
        self.writer.outputs.blocksChanged(changes[0..change_count]);
        return changed;
    }
};
