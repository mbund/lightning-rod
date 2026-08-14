const block_store = @import("../world/blocks.zig");
const geometry = @import("../world/geometry.zig");
const std = @import("std");
const registry = @import("registry_data");
const view = @import("../view.zig");

test "player overlays affect only their block and chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var player_view: view.PlayerView = .{};
    try player_view.allocate(arena.allocator());

    const pos = geometry.BlockPos{ .x = 17, .y = 64, .z = -1 };
    const chunk = geometry.chunkForBlock(pos);
    try player_view.setOverlay(pos, registry.block_stone_default_state);
    try std.testing.expectEqual(
        view.ChunkProjection.personalized,
        player_view.chunkProjection(chunk),
    );
    try std.testing.expectEqual(
        view.ChunkProjection.canonical,
        player_view.chunkProjection(.{ .x = 0, .z = 0 }),
    );

    var states = [_]i32{registry.block_air_default_state} **
        block_store.blocks_per_section;
    player_view.applySectionOverlays(
        chunk,
        block_store.sectionIndexForY(pos.y).?,
        &states,
    );
    const local: usize = 1 | (15 << 4) | (0 << 8);
    try std.testing.expectEqual(registry.block_stone_default_state, states[local]);

    try std.testing.expect(player_view.removeOverlay(pos));
    try std.testing.expectEqual(
        view.ChunkProjection.canonical,
        player_view.chunkProjection(chunk),
    );
}
