const std = @import("std");
const sessions = @import("sessions");
const wire = @import("wire_1_21_5");
const Players = @import("players.zig").Players;
const Input = @import("input.zig").Input;
const ItemActions = @import("item_actions.zig").ItemActions;
const BlockSynchronization = @import("block_sync.zig").BlockSynchronization;

pub const ItemUse = struct {
    pub const id = "minecraft:item_use";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *Players, input: *Input, actions: *ItemActions, blocks: *BlockSynchronization };
    const Sequence = struct { generation: u32 = 0, pending: i32 = -1 };
    deps: Dependencies,
    sequences: []Sequence,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemUse {
        const self = try allocator.create(ItemUse);
        self.* = .{ .deps = deps, .sequences = try allocator.alloc(Sequence, deps.players.records.len) };
        @memset(self.sequences, .{});
        try deps.input.on(.use_item, self, onUse);
        return self;
    }

    fn onUse(self: *ItemUse, handle: sessions.Handle, packet: wire.play.toServer.packet_use_item.Reader) !void {
        const hand, const a = try packet.hand();
        const sequence, const b = try a.sequence();
        var rotation = try b.rotation();
        const yaw, const c = try (try rotation.begin()).x();
        const pitch, const d = try c.y();
        try (try rotation.advance(d)).finish();
        if (!std.math.isFinite(yaw) or !std.math.isFinite(pitch) or hand < 0 or hand > 1 or sequence < 0) return error.InvalidPacket;
        var player = self.deps.players.records[handle.index];
        if (player.stage != .ready) return;
        player.rotation = .{ .yaw = @mod(yaw, 360), .pitch = std.math.clamp(pitch, -90, 90) };
        const state = &self.sequences[handle.index];
        if (state.generation != handle.generation) state.* = .{ .generation = handle.generation };
        state.pending = @max(state.pending, sequence);
        _ = try self.deps.actions.apply(&player, hand, null);
    }

    pub fn tick(self: *ItemUse) void {
        for (self.deps.players.activeSlots()) |index| {
            const player = self.deps.players.records[index];
            const handle = player.handle orelse continue;
            const state = &self.sequences[index];
            if (state.generation != handle.generation or state.pending < 0 or player.stage != .ready or self.deps.blocks.observers[index].pending != 0) continue;
            if (self.deps.players.sendBlockAck(player.protocol, handle, state.pending)) state.pending = -1;
        }
    }
};
