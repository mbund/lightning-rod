const std = @import("std");
const registry = @import("registry_data");
const terrain = @import("../terrain.zig");
const geometry = @import("../world/geometry.zig");
const world_identity = @import("../world/identity.zig");
const block_store = @import("../world/blocks.zig");
const test_generator = @import("world_generator.zig");

const Blocks = block_store.Blocks;
const blocks_per_section = block_store.blocks_per_section;
const sectionIndexForY = block_store.sectionIndexForY;
const localBlockIndexForPosition = block_store.localBlockIndexForPosition;
const test_world = world_identity.Handle{ .index = 0, .generation = 1 };
const air_block_state = registry.block_air_default_state;
const stone_block_default_state = registry.block_stone_default_state;
const dirt_block_default_state = registry.block_dirt_default_state;
const sparse_section_change_capacity = 32;
const materialization_lookup_slots = test_generator.block_configuration.maximum_transient_chunks * 2;

fn isRandomTickableBlock(block_state: i32) bool {
    return registry.randomTickState(block_state).kind != .none;
}

fn generatedHeightHash(world: world_identity.Handle, chunk: geometry.ChunkPos) usize {
    var value: u64 = 0xd6e8_feb8_6659_fd93;
    value ^= @as(u32, @bitCast(world));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(chunk.x));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(chunk.z));
    value *%= 0xe703_7ed1_a0b4_28db;
    value ^= value >> 32;
    return @intCast(value);
}

test "compact random tick projection exactly matches authoritative base and overlays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x636f_6c75_6d6e_73);
    generator.mode = .flat;
    const chunk = geometry.ChunkPos{ .x = 0, .z = 0 };
    const materialized = value.materializeGeneratedChunk(test_world, chunk, 0);
    const resident = value.ensureMaterializedRandomTickDerived(materialized.index);

    var sections = resident.random_tick_sections;
    while (sections != 0) {
        const section: usize = @intCast(@ctz(sections));
        sections &= sections - 1;
        for (0..blocks_per_section) |index| {
            const local_index: u16 = @intCast(index);
            const state = value.sectionRandomTickBlockState(
                resident,
                section,
                local_index,
                null,
            );
            const expected = value.sectionBlockState(resident, section, local_index, null);
            try std.testing.expectEqual(isRandomTickableBlock(expected), state != null);
            if (state) |actual| try std.testing.expectEqual(expected, actual);
        }
    }

    const surface = geometry.BlockPos{ .x = 3, .y = value.surfaceHeightAt(test_world, 3, 3), .z = 3 };
    try std.testing.expect(try value.setBlock(test_world, surface, dirt_block_default_state));
    const section = sectionIndexForY(surface.y).?;
    const modified = value.findModifiedSection(test_world, chunk, section).?;
    try std.testing.expectEqual(@as(?i32, null), value.sectionRandomTickBlockState(resident, section, localBlockIndexForPosition(surface), modified));
}

test "block mutation history preserves authoritative old and new states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 17);
    generator.mode = .flat;
    const pos = geometry.BlockPos{ .x = 3, .y = 0, .z = -5 };
    value.ensureChunkAt(test_world, pos.x, pos.z, 0);
    const previous = value.blockAt(test_world, pos);
    const replacement = if (previous == air_block_state) stone_block_default_state else air_block_state;
    try std.testing.expect(try value.setBlock(test_world, pos, replacement));
    try std.testing.expectEqual(@as(u64, 1), value.block_mutation_sequence);
    try std.testing.expectEqual(geometry.BlockMutation{
        .world = test_world,
        .pos = pos,
        .previous_state = previous,
        .block_state = replacement,
    }, value.blockMutation(1));
}

test "unchanged block in modified section reads authoritative base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x7370_6172_7365);
    generator.mode = .flat;
    const chunk = geometry.ChunkPos{ .x = 0, .z = 0 };
    _ = value.materializeGeneratedChunk(test_world, chunk, 0);
    const changed = geometry.BlockPos{ .x = 0, .y = value.surfaceHeightAt(test_world, 0, 0), .z = 0 };
    try std.testing.expect(try value.setBlock(test_world, changed, air_block_state));
    const section = sectionIndexForY(changed.y).?;
    const table_index = value.findModifiedSection(test_world, chunk, section).?;
    const resident = value.materializedChunk(test_world, chunk).?;

    const unchanged = geometry.BlockPos{ .x = 1, .y = changed.y, .z = 0 };
    const local_index = localBlockIndexForPosition(unchanged);
    try std.testing.expect(!value.sectionBlockIsModified(table_index, local_index));
    try std.testing.expect(!value.modified_sections[table_index].dense);
    const expected = terrain.blockAtFromShape(&resident.shape, unchanged.x, unchanged.y, unchanged.z);
    try std.testing.expectEqual(expected, value.sectionBlockState(resident, section, local_index, table_index));
}

test "modified section promotes only after sparse capacity is exceeded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x6465_6e73_652d_3333);
    generator.mode = .flat;
    const chunk = geometry.ChunkPos{ .x = 0, .z = 0 };
    _ = value.materializeGeneratedChunk(test_world, chunk, 0);
    const y: i16 = 100;
    const section = sectionIndexForY(y).?;

    for (0..sparse_section_change_capacity) |index| {
        const pos = geometry.BlockPos{ .x = @intCast(index & 15), .y = y, .z = @intCast(index >> 4) };
        try std.testing.expect(try value.setBlock(test_world, pos, stone_block_default_state));
    }
    var table_index = value.findModifiedSection(test_world, chunk, section).?;
    try std.testing.expect(!value.modified_sections[table_index].dense);
    try std.testing.expectEqual(@as(u8, sparse_section_change_capacity), value.modified_sections[table_index].sparse_count);
    try std.testing.expect(!value.dense_section_pool_initialized);

    const promoted = geometry.BlockPos{ .x = 0, .y = y, .z = 2 };
    try std.testing.expect(try value.setBlock(test_world, promoted, stone_block_default_state));
    table_index = value.findModifiedSection(test_world, chunk, section).?;
    try std.testing.expect(value.modified_sections[table_index].dense);
    try std.testing.expectEqual(@as(u16, sparse_section_change_capacity + 1), value.modified_sections[table_index].modified_count);
    try std.testing.expectEqual(
        test_generator.block_configuration.maximum_modified_sections - 1,
        value.availableDenseSections(),
    );
    try std.testing.expectEqual(stone_block_default_state, value.blockAt(test_world, promoted));
}

test "dense modified section storage reuses its fixed buffer after clean eviction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 1,
        .maximum_block_mutations = 128,
    });
    try generator.init(arena.allocator(), 0x6465_6e73_655f_7265);
    generator.mode = .flat;
    generator.bind(value);

    const first = geometry.ChunkPos{ .x = 0, .z = 0 };
    _ = value.materializeGeneratedChunk(test_world, first, 1);
    for (0..sparse_section_change_capacity + 1) |index| {
        const pos = geometry.BlockPos{ .x = @intCast(index & 15), .y = 100, .z = @intCast(index >> 4) };
        try std.testing.expect(try value.setBlock(test_world, pos, stone_block_default_state));
    }
    const section = sectionIndexForY(100).?;
    const first_table = value.findModifiedSection(test_world, first, section).?;
    try std.testing.expect(value.modified_sections[first_table].dense);
    const first_buffer = @intFromPtr(value.sectionBlocks(first_table).ptr);
    try std.testing.expectEqual(@as(usize, 0), value.availableDenseSections());
    try std.testing.expectEqual(stone_block_default_state, value.blockAt(test_world, .{ .x = 0, .y = 100, .z = 0 }));

    value.markChunkCleanThrough(test_world, first, value.chunkDirtyRevision(test_world, first));
    try std.testing.expect(value.evictChunk(test_world, first));
    try std.testing.expectEqual(@as(usize, 1), value.availableDenseSections());

    const second = geometry.ChunkPos{ .x = 1, .z = 0 };
    _ = value.materializeGeneratedChunk(test_world, second, 2);
    for (0..sparse_section_change_capacity + 1) |index| {
        const pos = geometry.BlockPos{ .x = second.x * 16 + @as(i32, @intCast(index & 15)), .y = 100, .z = 8 + @as(i32, @intCast(index >> 4)) };
        try std.testing.expect(try value.setBlock(test_world, pos, dirt_block_default_state));
    }
    const second_table = value.findModifiedSection(test_world, second, section).?;
    try std.testing.expect(value.modified_sections[second_table].dense);
    try std.testing.expectEqual(first_buffer, @intFromPtr(value.sectionBlocks(second_table).ptr));
    try std.testing.expectEqual(air_block_state, value.blockAt(test_world, .{ .x = 16, .y = 100, .z = 0 }));
    try std.testing.expectEqual(dirt_block_default_state, value.blockAt(test_world, .{ .x = 16, .y = 100, .z = 8 }));
}

test "materialization cycle releases clean snapshots and preserves dirty chunks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 4,
    });
    try generator.init(arena.allocator(), 0x7469_636b_6574_73);
    generator.mode = .flat;
    generator.bind(value);

    for (0..3) |x|
        _ = value.materializeGeneratedChunk(test_world, .{ .x = @intCast(x), .z = 0 }, 1);
    value.markChunkCleanThrough(test_world, .{ .x = 0, .z = 0 }, value.chunkDirtyRevision(test_world, .{ .x = 0, .z = 0 }));
    value.markChunkCleanThrough(test_world, .{ .x = 1, .z = 0 }, value.chunkDirtyRevision(test_world, .{ .x = 1, .z = 0 }));
    try std.testing.expect(try value.setBlock(
        test_world,
        .{ .x = 2 * 16, .y = 80, .z = 0 },
        stone_block_default_state,
    ));

    try std.testing.expectEqual(@as(usize, 2), value.releaseUnusedMaterializations());
    try std.testing.expect(value.materializedChunk(test_world, .{ .x = 0, .z = 0 }) == null);
    try std.testing.expect(value.materializedChunk(test_world, .{ .x = 1, .z = 0 }) == null);
    try std.testing.expect(value.materializedChunk(test_world, .{ .x = 2, .z = 0 }) != null);
}

test "clean materializations are released at the tick boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 4,
    });
    try generator.init(arena.allocator(), 0x7374_7265_616d);
    generator.mode = .flat;
    generator.bind(value);

    const generated = value.materializeGeneratedChunk(test_world, .{ .x = 0, .z = 0 }, 1);
    try std.testing.expectEqual(@as(usize, 0), value.releaseUnusedMaterializations());
    value.markChunkCleanThrough(test_world, generated.entry.chunk, value.chunkDirtyRevision(test_world, generated.entry.chunk));
    try std.testing.expectEqual(@as(usize, 1), value.releaseUnusedMaterializations());
}

test "newly generated chunks remain resident until their terrain is durable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x7061_6765_6162_6c65);
    generator.mode = .flat;

    const chunk = geometry.ChunkPos{ .x = 0, .z = 0 };
    _ = value.materializeGeneratedChunk(test_world, chunk, 1);
    try std.testing.expect(value.markGeneratedChunkNew(test_world, chunk));
    const resident = value.materializedChunk(test_world, chunk).?;
    try std.testing.expect(resident.dirty);
    try std.testing.expect(value.chunkDirtyRevision(test_world, chunk) != 0);
    try std.testing.expect(!value.evictChunk(test_world, chunk));
    value.markChunkCleanThrough(test_world, chunk, value.chunkDirtyRevision(test_world, chunk));
    try std.testing.expect(value.evictChunk(test_world, chunk));
}

test "resident lookup survives eviction inside a probe cluster" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x8a7b_6c5d);
    generator.mode = .flat;

    const mask = materialization_lookup_slots - 1;
    var first_by_bucket = [_]i32{-1} ** materialization_lookup_slots;
    var first: ?geometry.ChunkPos = null;
    var second: ?geometry.ChunkPos = null;
    for (0..materialization_lookup_slots + 1) |x| {
        const candidate = geometry.ChunkPos{ .x = @intCast(x), .z = 0 };
        const bucket = generatedHeightHash(test_world, candidate) & mask;
        if (first_by_bucket[bucket] < 0) {
            first_by_bucket[bucket] = candidate.x;
            continue;
        }
        first = .{ .x = first_by_bucket[bucket], .z = 0 };
        second = candidate;
        break;
    }
    const collided_first = first orelse return error.TestExpectedEqual;
    const collided = second orelse return error.TestExpectedEqual;

    _ = value.materializeGeneratedChunk(test_world, collided_first, 1);
    _ = value.materializeGeneratedChunk(test_world, collided, 2);
    value.markChunkCleanThrough(test_world, collided_first, value.chunkDirtyRevision(test_world, collided_first));
    try std.testing.expect(value.materializedChunk(test_world, collided_first) != null);
    try std.testing.expect(value.materializedChunk(test_world, collided) != null);
    try std.testing.expect(value.evictChunk(test_world, collided_first));
    try std.testing.expect(value.materializedChunk(test_world, collided_first) == null);
    try std.testing.expect(value.materializedChunk(test_world, collided) != null);
    try std.testing.expectEqual(@as(usize, 1), value.materializedChunkCount());
}

test "identical coordinates are isolated by world" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x776f_726c_642d_6b65);
    generator.mode = .void;

    const first = world_identity.Handle{ .index = 1, .generation = 1 };
    const second = world_identity.Handle{ .index = 2, .generation = 1 };
    const pos = geometry.BlockPos{ .x = 0, .y = 80, .z = 0 };
    value.ensureChunkAt(first, pos.x, pos.z, 1);
    value.ensureChunkAt(second, pos.x, pos.z, 1);
    try std.testing.expect(try value.setBlock(first, pos, stone_block_default_state));
    try std.testing.expect(try value.setBlock(second, pos, dirt_block_default_state));

    try std.testing.expectEqual(stone_block_default_state, value.blockAt(first, pos));
    try std.testing.expectEqual(dirt_block_default_state, value.blockAt(second, pos));
    try std.testing.expect(value.materializedChunk(first, .{ .x = 0, .z = 0 }) != value.materializedChunk(second, .{ .x = 0, .z = 0 }));
}
