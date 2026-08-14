const std = @import("std");
const registry = @import("registry_data");
const block_store = @import("../world/blocks.zig");
const geometry = @import("../world/geometry.zig");
const world_identity = @import("../world/identity.zig");
const collision = @import("../collision.zig");
const navigation = @import("../navigation.zig");
const queries = @import("../world/block_queries.zig");
const test_generator = @import("world_generator.zig");

const adjustLivingMovement = queries.adjustLivingMovement;
const livingBoxCollides = queries.livingBoxCollides;
const pathNodeInResident = queries.pathNodeInResident;

const test_world = world_identity.Handle{ .index = 0, .generation = 1 };

test "open trapdoors are pathfinding support but not collision support" {
    const open = registry.blockStateId("minecraft:oak_trapdoor[facing=north,half=bottom,open=true,powered=false,waterlogged=false]").?;
    const closed = registry.blockStateId("minecraft:oak_trapdoor[facing=north,half=bottom,open=false,powered=false,waterlogged=false]").?;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const blocks = try test_generator.createBlocks(&generator, arena.allocator(), 7);
    generator.mode = .flat;
    const pos = geometry.BlockPos{ .x = 0, .y = 64, .z = 0 };
    _ = try blocks.setBlock(test_world, pos, open);
    const resident = blocks.residentChunk(test_world, .{ .x = 0, .z = 0 }).?;
    const node = pathNodeInResident(blocks, resident, 0, 65, 0, false);
    try std.testing.expect(node.passable);
    try std.testing.expectEqual(navigation.NodeType.walkable, node.node.node_type);

    const body = collision.entityBox(0.5, 65, 0.5, 0.6, 1.95);
    _ = try blocks.setBlock(test_world, pos, closed);
    const closed_fall = adjustLivingMovement(blocks, test_world, body, .{ .y = -1 });
    _ = try blocks.setBlock(test_world, pos, open);
    const open_fall = adjustLivingMovement(blocks, test_world, body, .{ .y = -1 });
    try std.testing.expect(closed_fall.y > open_fall.y);
    try std.testing.expectEqual(@as(f64, -1), open_fall.y);
}

test "collision bounds are half open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const blocks = try test_generator.createBlocks(&generator, arena.allocator(), 0x636f_6c6c_6973_696f);
    generator.mode = .flat;
    try std.testing.expect(try blocks.setBlock(test_world, .{ .x = 0, .y = 100, .z = 0 }, registry.block_stone_default_state));
    blocks.ensureChunkAt(test_world, -1, 0, 0);

    const touching = collision.Box{ .min_x = -0.6, .min_y = 100.1, .min_z = 0.2, .max_x = 0, .max_y = 100.9, .max_z = 0.8 };
    try std.testing.expect(!livingBoxCollides(blocks, test_world, touching));
    try std.testing.expect(livingBoxCollides(blocks, test_world, .{ .min_x = -0.6, .min_y = 100.1, .min_z = 0.2, .max_x = 0.01, .max_y = 100.9, .max_z = 0.8 }));
    try std.testing.expectEqual(@as(f64, 0), adjustLivingMovement(blocks, test_world, touching, .{ .x = 0.5 }).x);
}

test "collision queries never generate missing terrain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const blocks = try test_generator.createBlocks(&generator, arena.allocator(), 0x7265_7369_6465_6e74);
    blocks.requestChunkGeneration(test_world, .{ .x = 0, .z = 0 });

    const body = collision.entityBox(8, 90, 8, 0.6, 1.8);
    try std.testing.expectEqual(collision.Movement{}, adjustLivingMovement(blocks, test_world, body, .{ .y = -0.08 }));
    try std.testing.expect(livingBoxCollides(blocks, test_world, body));
    try std.testing.expectEqual(@as(usize, 1), blocks.pendingChunkGenerationCount());
    try std.testing.expect(blocks.residentChunk(test_world, .{ .x = 0, .z = 0 }) == null);
}
