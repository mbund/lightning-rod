const std = @import("std");
const registry = @import("registry_data");
const config = @import("../config.zig").value;
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
const resident_chunk_lookup_slots = config.max_resident_chunks * 2;

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
    const resident = value.generatedHeightChunkRef(test_world, chunk, 0).entry;

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
    _ = value.generatedHeightChunkRef(test_world, chunk, 0);
    const changed = geometry.BlockPos{ .x = 0, .y = value.surfaceHeightAt(test_world, 0, 0), .z = 0 };
    try std.testing.expect(try value.setBlock(test_world, changed, air_block_state));
    const section = sectionIndexForY(changed.y).?;
    const table_index = value.findModifiedSection(test_world, chunk, section).?;
    const resident = value.residentChunk(test_world, chunk).?;

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
    _ = value.generatedHeightChunkRef(test_world, chunk, 0);
    const y: i16 = 100;
    const section = sectionIndexForY(y).?;

    for (0..sparse_section_change_capacity) |index| {
        const pos = geometry.BlockPos{ .x = @intCast(index & 15), .y = y, .z = @intCast(index >> 4) };
        try std.testing.expect(try value.setBlock(test_world, pos, stone_block_default_state));
    }
    var table_index = value.findModifiedSection(test_world, chunk, section).?;
    try std.testing.expect(!value.modified_sections[table_index].dense);
    try std.testing.expectEqual(@as(u8, sparse_section_change_capacity), value.modified_sections[table_index].sparse_count);
    try std.testing.expect(!value.page_pool_initialized);

    const promoted = geometry.BlockPos{ .x = 0, .y = y, .z = 2 };
    try std.testing.expect(try value.setBlock(test_world, promoted, stone_block_default_state));
    table_index = value.findModifiedSection(test_world, chunk, section).?;
    try std.testing.expect(value.modified_sections[table_index].dense);
    try std.testing.expectEqual(@as(u16, sparse_section_change_capacity + 1), value.modified_sections[table_index].modified_count);
    try std.testing.expectEqual(config.max_modified_sections - 1, value.availableSectionPages());
    try std.testing.expectEqual(stone_block_default_state, value.blockAt(test_world, promoted));
}

test "terrain generation batch discards stale view requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x7261_6469_616c_7669);
    generator.mode = .flat;

    const stale = geometry.ChunkPos{ .x = -32, .z = 0 };
    const current = geometry.ChunkPos{ .x = 33, .z = 0 };
    value.requestChunkGeneration(test_world, stale);
    value.beginChunkGenerationBatch();
    value.requestChunkGeneration(test_world, current);

    try std.testing.expectEqual(@as(usize, 1), value.pendingChunkGenerationCount());
    try std.testing.expectEqual(block_store.ChunkGenerationResult.complete, value.generateRequestedChunk(1));
    try std.testing.expect(value.residentChunk(test_world, stale) == null);
    const resident = value.residentChunk(test_world, current).?;
    try std.testing.expect(!resident.dirty);
    try std.testing.expect(!resident.persistence_known);
    try std.testing.expect(value.evictChunk(test_world, current));
    try std.testing.expect(value.residentChunk(test_world, current) == null);
    try std.testing.expectEqual(@as(usize, 0), value.pendingChunkGenerationCount());
}

test "terrain generation batch preserves its active request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(
        &generator,
        arena.allocator(),
        0x6163_7469_7665_5f67,
    );

    const active = geometry.ChunkPos{ .x = -2, .z = 3 };
    const later = geometry.ChunkPos{ .x = 9, .z = -7 };
    value.beginChunkGenerationBatch();
    value.requestChunkGeneration(test_world, active);
    try std.testing.expectEqual(
        block_store.ChunkGenerationResult.pending,
        value.generateRequestedChunk(1),
    );

    value.beginChunkGenerationBatch();
    value.requestChunkGeneration(test_world, later);
    try std.testing.expectEqual(@as(usize, 2), value.pendingChunkGenerationCount());
    for (0..4096) |_| {
        if (value.residentChunk(test_world, active) != null) break;
        try std.testing.expect(
            value.generateRequestedChunk(2) != .idle,
        );
    }
    try std.testing.expect(value.residentChunk(test_world, active) != null);
    try std.testing.expect(value.residentChunk(test_world, later) == null);
}

test "resident capacity applies backpressure and resumes after paging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try Blocks.create(arena.allocator(), .{
        .maximum_resident_chunks = 4,
        .maximum_modified_sections = 4,
    });
    try generator.init(arena.allocator(), 0x7061_6765_5f74_6573);
    generator.mode = .flat;
    generator.bind(value);

    for (0..4) |x| {
        value.beginChunkGenerationBatch();
        value.requestChunkGeneration(test_world, .{ .x = @intCast(x), .z = 0 });
        try std.testing.expectEqual(block_store.ChunkGenerationResult.complete, value.generateRequestedChunk(1));
    }
    value.beginChunkGenerationBatch();
    value.requestChunkGeneration(test_world, .{ .x = 4, .z = 0 });
    try std.testing.expectEqual(block_store.ChunkGenerationResult.backpressured, value.generateRequestedChunk(1));
    try std.testing.expect(value.residentPressure());

    try std.testing.expect(value.evictChunk(test_world, .{ .x = 0, .z = 0 }));
    value.clearResidentPressure();
    value.beginChunkGenerationBatch();
    value.requestChunkGeneration(test_world, .{ .x = 4, .z = 0 });
    try std.testing.expectEqual(block_store.ChunkGenerationResult.complete, value.generateRequestedChunk(2));
    try std.testing.expect(value.residentChunk(test_world, .{ .x = 4, .z = 0 }) != null);
}

test "resident ticket cycle evicts only clean unticketed chunks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try Blocks.create(arena.allocator(), .{
        .maximum_resident_chunks = 4,
        .maximum_modified_sections = 4,
    });
    try generator.init(arena.allocator(), 0x7469_636b_6574_73);
    generator.mode = .flat;
    generator.bind(value);

    for (0..3) |x|
        _ = value.generatedHeightChunkRef(test_world, .{ .x = @intCast(x), .z = 0 }, 1);
    value.residentChunkMut(test_world, .{ .x = 0, .z = 0 }).?.persistence_known = true;
    value.residentChunkMut(test_world, .{ .x = 1, .z = 0 }).?.persistence_known = true;
    try std.testing.expect(try value.setBlock(
        test_world,
        .{ .x = 2 * 16, .y = 80, .z = 0 },
        stone_block_default_state,
    ));

    value.beginResidentTickets();
    try std.testing.expect(value.ticketResidentChunk(test_world, .{ .x = 0, .z = 0 }));
    try std.testing.expectEqual(@as(usize, 1), value.evictUnticketedChunks());
    try std.testing.expect(value.residentChunk(test_world, .{ .x = 0, .z = 0 }) != null);
    try std.testing.expect(value.residentChunk(test_world, .{ .x = 1, .z = 0 }) == null);
    try std.testing.expect(value.residentChunk(test_world, .{ .x = 2, .z = 0 }) != null);
}

test "streaming releases only persisted unticketed chunks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try Blocks.create(arena.allocator(), .{
        .maximum_resident_chunks = 4,
        .maximum_modified_sections = 4,
    });
    try generator.init(arena.allocator(), 0x7374_7265_616d);
    generator.mode = .flat;
    generator.bind(value);

    const generated = value.generatedHeightChunkRef(test_world, .{ .x = 0, .z = 0 }, 1);
    try std.testing.expect(!value.residentChunkTicketed(test_world, .{ .x = 1, .z = 0 }));
    try std.testing.expect(value.releaseStreamedChunk(test_world, generated.entry.chunk) == null);
    value.residentChunkMut(test_world, generated.entry.chunk).?.persistence_known = true;
    value.beginResidentTickets();
    try std.testing.expect(value.ticketResidentChunk(test_world, generated.entry.chunk));
    try std.testing.expect(value.residentChunkTicketed(test_world, generated.entry.chunk));
    try std.testing.expect(value.releaseStreamedChunk(test_world, generated.entry.chunk) == null);
    value.beginResidentTickets();
    try std.testing.expect(value.releaseStreamedChunk(test_world, generated.entry.chunk) == null);
    value.beginResidentTickets();
    try std.testing.expect(value.releaseStreamedChunk(test_world, generated.entry.chunk) != null);
}

test "dirty resident slots become pageable only after write acknowledgement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try Blocks.create(arena.allocator(), .{
        .maximum_resident_chunks = 4,
        .maximum_modified_sections = 4,
    });
    try generator.init(arena.allocator(), 0x7772_6974_6562_6163);
    generator.mode = .flat;
    generator.bind(value);

    for (0..4) |x| {
        const chunk = geometry.ChunkPos{ .x = @intCast(x), .z = 0 };
        value.beginChunkGenerationBatch();
        value.requestChunkGeneration(test_world, chunk);
        try std.testing.expectEqual(block_store.ChunkGenerationResult.complete, value.generateRequestedChunk(1));
        const position = geometry.BlockPos{ .x = @as(i32, @intCast(x)) * 16, .y = 80, .z = 0 };
        try std.testing.expect(try value.setBlock(test_world, position, stone_block_default_state));
        try std.testing.expect(!value.evictChunk(test_world, chunk));
    }

    value.beginChunkGenerationBatch();
    value.requestChunkGeneration(test_world, .{ .x = 4, .z = 0 });
    try std.testing.expectEqual(block_store.ChunkGenerationResult.backpressured, value.generateRequestedChunk(1));
    const revision = value.chunkDirtyRevision(test_world, .{ .x = 0, .z = 0 });
    value.markChunkCleanThrough(test_world, .{ .x = 0, .z = 0 }, revision);
    try std.testing.expect(value.evictChunk(test_world, .{ .x = 0, .z = 0 }));

    value.clearResidentPressure();
    value.beginChunkGenerationBatch();
    value.requestChunkGeneration(test_world, .{ .x = 4, .z = 0 });
    try std.testing.expectEqual(block_store.ChunkGenerationResult.complete, value.generateRequestedChunk(2));
}

test "resident lookup survives eviction inside a probe cluster" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const value = try test_generator.createBlocks(&generator, arena.allocator(), 0x8a7b_6c5d);
    generator.mode = .flat;

    const mask = resident_chunk_lookup_slots - 1;
    var first_by_bucket = [_]i32{-1} ** resident_chunk_lookup_slots;
    var first: ?geometry.ChunkPos = null;
    var second: ?geometry.ChunkPos = null;
    for (0..resident_chunk_lookup_slots + 1) |x| {
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

    _ = value.generatedHeightChunkRef(test_world, collided_first, 1);
    _ = value.generatedHeightChunkRef(test_world, collided, 2);
    try std.testing.expect(value.residentChunk(test_world, collided_first) != null);
    try std.testing.expect(value.residentChunk(test_world, collided) != null);
    try std.testing.expect(value.evictChunk(test_world, collided_first));
    try std.testing.expect(value.residentChunk(test_world, collided_first) == null);
    try std.testing.expect(value.residentChunk(test_world, collided) != null);
    try std.testing.expectEqual(@as(usize, 1), value.residentChunkCount());
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
    try std.testing.expect(try value.setBlock(first, pos, stone_block_default_state));
    try std.testing.expect(try value.setBlock(second, pos, dirt_block_default_state));

    try std.testing.expectEqual(stone_block_default_state, value.blockAt(first, pos));
    try std.testing.expectEqual(dirt_block_default_state, value.blockAt(second, pos));
    try std.testing.expect(value.residentChunk(first, .{ .x = 0, .z = 0 }) != value.residentChunk(second, .{ .x = 0, .z = 0 }));
}
