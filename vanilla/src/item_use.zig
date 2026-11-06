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
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemUse {
        const self = try allocator.create(ItemUse);
        self.* = .{ .deps = deps };
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
        self.deps.blocks.acknowledge(&player, sequence);
        _ = try self.deps.actions.apply(&player, hand, null);
    }
};
