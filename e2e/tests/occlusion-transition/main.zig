const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const sessions = @import("sessions");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 1, .render_distance = 32, .spawn = .{ .x = 20.5, .y = 17, .z = 20.5 } }),
            lightning_rod.plugin.configured(vanilla.Streaming, .{ .prefetch = 2 }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

const Probe = struct {
    pub const id = "e2e:occlusion_transition";
    pub const Configuration = struct {};
    pub const Dependencies = struct { control: *e2e.Control, players: *vanilla.Players, chunks: *vanilla.Chunks };
    deps: Dependencies,
    ascending: bool = false,
    lamp: enum { initial, extinguished, restored } = .initial,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        const edits = try allocator.alloc(vanilla.BlockEdit, 4096);
        defer allocator.free(edits);
        for (edits, 0..) |*edit, index| edit.* = .{ .index = @intCast(index), .state = if (index < 256) @intCast(protocols.registry.block_stone_default_state) else 0 };
        edits[4 * 16 + 4].state = @intCast(protocols.registry.block_glowstone_default_state);
        try deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = 1, .z = 1 }, edits);
        for ([_]i32{ 2, 4, 8, 16, 32 }) |distance| for ([_]i32{ 80, 112, 144 }) |height| {
            try deps.chunks.setBlock(0, .{ .x = (1 + distance) * 16 + 8, .y = height, .z = 24 }, @intCast(protocols.registry.block_gold_block_default_state));
        };
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "lamp_off")) {
            if (self.lamp != .initial or self.ascending) return error.InvalidLampTransition;
            try self.deps.chunks.setBlock(0, .{ .x = 20, .y = 16, .z = 20 }, @intCast(protocols.registry.block_stone_default_state));
            self.lamp = .extinguished;
            return .handled;
        }
        if (std.mem.eql(u8, text, "lamp_on")) {
            if (self.lamp != .extinguished or self.ascending) return error.InvalidLampTransition;
            try self.deps.chunks.setBlock(0, .{ .x = 20, .y = 16, .z = 20 }, @intCast(protocols.registry.block_glowstone_default_state));
            self.lamp = .restored;
            return .handled;
        }
        if (!std.mem.eql(u8, text, "ascend")) return .unhandled;
        if (self.ascending or self.lamp != .restored) return error.InvalidAscent;
        self.ascending = true;
        const player = &self.deps.players.records[handle.index];
        try self.deps.players.teleport(player, player.world, .{ .x = 20.5, .y = 65, .z = 20.5 }, .{ .yaw = 0, .pitch = 10 });
        return .handled;
    }
};
