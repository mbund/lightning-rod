const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla_persistence = @import("vanilla_persistence.zig");

const block_store = lightning_rod.blocks;
const collision = lightning_rod.collision;
const geometry = lightning_rod.geometry;
const registry = lightning_rod.registry_data;
const world_identity = lightning_rod.world_identity;
const world_limits = lightning_rod.world_limits;

const words_per_section = block_store.blocks_per_section / 64;
const empty_mask: u16 = 0;
const full_mask: u16 = std.math.maxInt(u16);

const Entry = struct {
    world: world_identity.Handle = world_identity.invalid,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    source_content_revision: u64 = 0,
    projection_revision: u64 = 0,
    last_used_tick: u64 = 0,
    exception_count: u16 = 0,
    fluid_span_count: u16 = 0,
    valid: bool = false,
    complete: bool = false,
};

const FluidSpan = struct {
    column: u8,
    min_y: i16,
    max_y: i16,
    block_state: i32,
};

test "collision section shortcuts match materialized blocks and fluid spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const blocks = try block_store.Blocks.init(allocator, .{ .maximum_transient_chunks = 4, .maximum_modified_sections = 8 });
    var generator: lightning_rod.test_support.world_generator.Generator = .{ .mode = .flat };
    generator.bind(blocks);
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    const resident = blocks.materializeGeneratedChunk(world, .{ .x = 0, .z = 0 }, 1).entry;
    for ([_]i32{ 79, 80, 111, 144 }) |y| {
        _ = try blocks.setBlock(world, .{ .x = 2, .y = @intCast(y), .z = 3 }, registry.state_water_level_0);
    }
    var clock: lightning_rod.clock.Clock = .{};
    var materialization: vanilla_persistence.Materializer = undefined;
    const projection = try CollisionProjection.init(allocator, .{ .clock = &clock, .blocks = blocks, .materialization = &materialization }, .{ .maximum_chunks = 1 });
    const projection_revision = projection.revision(world, resident.chunk).?;
    try std.testing.expect(projection.entries[0].complete);
    for (0..world_limits.section_count) |section| {
        const encoded = resident.modified_section_indices[section];
        const modified: ?usize = if (encoded == block_store.no_modified_section_index) null else encoded;
        for (0..block_store.blocks_per_section) |raw_local| {
            const local: u16 = @intCast(raw_local);
            const state = blocks.sectionBlockState(resident, section, local, modified);
            const shapes = collision.shapeBoxes(state);
            const full = shapes.len == 1 and shapes[0].min_x == 0 and shapes[0].min_y == 0 and shapes[0].min_z == 0 and
                shapes[0].max_x == 64 and shapes[0].max_y == 64 and shapes[0].max_z == 64;
            try std.testing.expectEqual(full, projection.maskBit(projection.collision_handles, projection.collision_masks, 0, section, local));
            try std.testing.expectEqual(registry.blockBehaviorFlags(state).flammable, projection.maskBit(projection.flammable_handles, projection.flammable_masks, 0, section, local));
        }
    }
    const expected = [_]FluidSpan{
        .{ .column = 50, .min_y = 79, .max_y = 80, .block_state = registry.state_water_level_0 },
        .{ .column = 50, .min_y = 111, .max_y = 111, .block_state = registry.state_water_level_0 },
        .{ .column = 50, .min_y = 144, .max_y = 144, .block_state = registry.state_water_level_0 },
    };
    try std.testing.expectEqualDeep(&expected, projection.fluid_spans[0..projection.entries[0].fluid_span_count]);

    const chunk = resident.chunk;
    const shape = resident.shape;
    const content_revision = resident.content_revision;
    _ = try blocks.installPersistedMaterialization(world, shape, 2, content_revision);
    blocks.finishPersistedMaterialization(world, chunk, content_revision);
    projection.consumeMaterializations();
    try std.testing.expectEqual(projection_revision, projection.revision(world, chunk).?);

    _ = try blocks.setBlock(world, .{ .x = 2, .y = 79, .z = 3 }, registry.block_dirt_default_state);
    projection.consumeMutations();
    try std.testing.expect(projection.entries[0].complete);
    try std.testing.expectEqual(@as(u64, 0), projection.entries[0].source_content_revision);
    const mutation_revision = projection.revision(world, chunk).?;
    try std.testing.expect(mutation_revision != projection_revision);

    projection.remove(0);
    try std.testing.expect(projection.revision(world, chunk).? != mutation_revision);
}

pub const CollisionProjection = struct {
    pub const id = "minecraft:collision_projection";

    pub const Configuration = struct {
        maximum_chunks: usize = 512,
        maximum_exceptions_per_chunk: usize = 128,
        maximum_fluid_spans_per_chunk: usize = 256,
        maximum_collision_masks: usize = 1_024,
        maximum_flammable_masks: usize = 512,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_chunks == 0 or self.maximum_chunks >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_chunks) or
                self.maximum_exceptions_per_chunk == 0 or self.maximum_exceptions_per_chunk >= std.math.maxInt(u16) or
                self.maximum_fluid_spans_per_chunk == 0 or self.maximum_fluid_spans_per_chunk >= std.math.maxInt(u16) or
                self.maximum_collision_masks == 0 or self.maximum_collision_masks >= full_mask or
                self.maximum_flammable_masks == 0 or self.maximum_flammable_masks >= full_mask)
                return error.InvalidCollisionProjectionCapacity;
        }
    };

    pub const Dependencies = struct {
        clock: *lightning_rod.clock.Clock,
        blocks: *block_store.Blocks,
        materialization: *vanilla_persistence.Materializer,
        runtime_metrics: ?*lightning_rod.metrics.Runtime = null,
    };

    deps: Dependencies,
    exceptions_per_chunk: usize,
    fluid_spans_per_chunk: usize,
    observed_mutation_sequence: u64,
    observed_materialization_sequence: u64,
    next_projection_revision: u64 = 1,
    entries: []Entry,
    lookup: []u16,
    collision_handles: []u16,
    flammable_handles: []u16,
    collision_masks: [][words_per_section]u64,
    flammable_masks: [][words_per_section]u64,
    free_collision_masks: []u16,
    free_flammable_masks: []u16,
    free_collision_mask_count: usize,
    free_flammable_mask_count: usize,
    heights: []i16,
    surface_states: []i32,
    grass_surfaces: []u64,
    exception_positions: []u32,
    exception_states: []i32,
    fluid_spans: []FluidSpan,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*CollisionProjection {
        try configuration.validate();
        const self = try allocator.create(CollisionProjection);
        self.* = .{
            .deps = deps,
            .exceptions_per_chunk = configuration.maximum_exceptions_per_chunk,
            .fluid_spans_per_chunk = configuration.maximum_fluid_spans_per_chunk,
            .observed_mutation_sequence = deps.blocks.mutationCursor().sequence,
            .observed_materialization_sequence = deps.blocks.materializationCursor().sequence,
            .entries = try allocator.alloc(Entry, configuration.maximum_chunks),
            .lookup = try allocator.alloc(u16, configuration.maximum_chunks * 2),
            .collision_handles = try allocator.alloc(u16, configuration.maximum_chunks * world_limits.section_count),
            .flammable_handles = try allocator.alloc(u16, configuration.maximum_chunks * world_limits.section_count),
            .collision_masks = try allocator.alignedAlloc([words_per_section]u64, .@"64", configuration.maximum_collision_masks),
            .flammable_masks = try allocator.alignedAlloc([words_per_section]u64, .@"64", configuration.maximum_flammable_masks),
            .free_collision_masks = try allocator.alloc(u16, configuration.maximum_collision_masks),
            .free_flammable_masks = try allocator.alloc(u16, configuration.maximum_flammable_masks),
            .free_collision_mask_count = configuration.maximum_collision_masks,
            .free_flammable_mask_count = configuration.maximum_flammable_masks,
            .heights = try allocator.alloc(i16, configuration.maximum_chunks * 16 * 16),
            .surface_states = try allocator.alloc(i32, configuration.maximum_chunks * 16 * 16),
            .grass_surfaces = try allocator.alloc(u64, configuration.maximum_chunks * 4),
            .exception_positions = try allocator.alloc(u32, configuration.maximum_chunks * configuration.maximum_exceptions_per_chunk),
            .exception_states = try allocator.alloc(i32, configuration.maximum_chunks * configuration.maximum_exceptions_per_chunk),
            .fluid_spans = try allocator.alloc(FluidSpan, configuration.maximum_chunks * configuration.maximum_fluid_spans_per_chunk),
        };
        @memset(self.entries, .{});
        @memset(self.lookup, 0);
        @memset(self.collision_handles, empty_mask);
        @memset(self.flammable_handles, empty_mask);
        for (self.free_collision_masks, 0..) |*index, position| index.* = @intCast(self.free_collision_masks.len - position - 1);
        for (self.free_flammable_masks, 0..) |*index, position| index.* = @intCast(self.free_flammable_masks.len - position - 1);
        @memset(self.grass_surfaces, 0);
        return self;
    }

    pub fn tick(self: *CollisionProjection, _: std.mem.Allocator) void {
        self.consumeMaterializations();
        self.consumeMutations();
        if (self.deps.runtime_metrics) |runtime| {
            var chunks: usize = 0;
            var exceptions: usize = 0;
            var fluid_spans: usize = 0;
            var incomplete_chunks: usize = 0;
            for (self.entries) |entry| if (entry.valid) {
                chunks += 1;
                exceptions += entry.exception_count;
                fluid_spans += entry.fluid_span_count;
                incomplete_chunks += @intFromBool(!entry.complete);
            };
            runtime.setCollisionProjections(
                chunks,
                self.entries.len,
                exceptions,
                self.exception_positions.len,
                fluid_spans,
                self.fluid_spans.len,
                incomplete_chunks,
                self.collision_masks.len - self.free_collision_mask_count + self.flammable_masks.len - self.free_flammable_mask_count,
                self.collision_masks.len + self.flammable_masks.len,
            );
        }
    }

    pub fn blockState(self: *CollisionProjection, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        if (self.deps.blocks.blockAtIfMaterialized(world, pos)) |state| return state;
        const chunk = geometry.chunkForBlock(pos);
        const slot = self.ensure(world, chunk) orelse return null;
        const entry = &self.entries[slot];
        if (!entry.complete) return self.deps.blocks.blockAtIfMaterialized(world, pos);
        const section = block_store.sectionIndexForY(pos.y) orelse return registry.block_air_default_state;
        const local = block_store.localBlockIndexForPosition(pos);
        const position_index: u32 = @intCast(section * block_store.blocks_per_section + local);
        const column_index: usize = @as(usize, local & 15) + @as(usize, (local >> 4) & 15) * 16;
        const base = slot * self.exceptions_per_chunk;
        for (self.exception_positions[base..][0..entry.exception_count], 0..) |position, index|
            if (position == position_index) return self.exception_states[base + index];
        if (pos.y == self.heights[slot * 256 + column_index]) return self.surface_states[slot * 256 + column_index];
        const column: u8 = @intCast(@as(usize, local & 15) + @as(usize, (local >> 4) & 15) * 16);
        const fluid_base = slot * self.fluid_spans_per_chunk;
        for (self.fluid_spans[fluid_base..][0..entry.fluid_span_count]) |span|
            if (span.column == column and pos.y >= span.min_y and pos.y <= span.max_y) return span.block_state;
        if (self.maskBit(self.collision_handles, self.collision_masks, slot, section, local))
            return registry.block_stone_default_state;
        return registry.block_air_default_state;
    }

    pub fn source(self: *CollisionProjection) lightning_rod.block_queries.BlockStates {
        return .{ .context = self, .at_fn = projectedBlockState };
    }

    fn projectedBlockState(context: *anyopaque, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        const self: *CollisionProjection = @ptrCast(@alignCast(context));
        return self.blockState(world, pos);
    }

    pub fn contains(self: *CollisionProjection, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        return if (self.find(world, chunk)) |slot| self.entries[slot].complete else false;
    }

    pub fn revision(self: *CollisionProjection, world: world_identity.Handle, chunk: geometry.ChunkPos) ?u64 {
        const slot = self.ensure(world, chunk) orelse return null;
        return if (self.entries[slot].complete) self.entries[slot].projection_revision else null;
    }

    pub fn highestBlockYAt(self: *CollisionProjection, world: world_identity.Handle, x: i32, z: i32) ?i16 {
        const slot = self.ensure(world, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }) orelse return null;
        if (!self.entries[slot].complete) return null;
        return self.heights[slot * 256 + @as(usize, @intCast(x & 15)) + @as(usize, @intCast(z & 15)) * 16];
    }

    pub fn surfaceIsGrass(self: *CollisionProjection, world: world_identity.Handle, x: i32, z: i32) bool {
        const slot = self.ensure(world, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }) orelse return false;
        if (!self.entries[slot].complete) return false;
        const column: usize = @as(usize, @intCast(x & 15)) + @as(usize, @intCast(z & 15)) * 16;
        return self.grass_surfaces[slot * 4 + column / 64] & (@as(u64, 1) << @intCast(column & 63)) != 0;
    }

    pub fn flammableAt(self: *CollisionProjection, world: world_identity.Handle, pos: geometry.BlockPos) bool {
        const slot = self.ensure(world, geometry.chunkForBlock(pos)) orelse return false;
        if (!self.entries[slot].complete) return false;
        const section = block_store.sectionIndexForY(pos.y) orelse return false;
        return self.maskBit(self.flammable_handles, self.flammable_masks, slot, section, block_store.localBlockIndexForPosition(pos));
    }

    fn ensure(self: *CollisionProjection, world: world_identity.Handle, chunk: geometry.ChunkPos) ?usize {
        if (self.find(world, chunk)) |slot| {
            self.entries[slot].last_used_tick = self.deps.clock.tick;
            if (!self.entries[slot].complete) {
                if (self.deps.blocks.materializedChunk(world, chunk)) |resident| {
                    if (self.entries[slot].source_content_revision != resident.content_revision)
                        self.rebuild(slot, resident);
                } else if (self.entries[slot].source_content_revision == 0) {
                    _ = self.deps.materialization.requestProjection(world, chunk);
                }
            }
            return slot;
        }
        const slot = self.freeOrOldest();
        if (self.entries[slot].valid) self.remove(slot);
        self.entries[slot] = .{ .world = world, .chunk = chunk, .last_used_tick = self.deps.clock.tick, .valid = true };
        self.insert(slot);
        if (self.deps.blocks.materializedChunk(world, chunk)) |resident|
            self.rebuild(slot, resident)
        else
            _ = self.deps.materialization.requestProjection(world, chunk);
        return slot;
    }

    fn consumeMaterializations(self: *CollisionProjection) void {
        var cursor = self.deps.blocks.materializationCursorFrom(self.observed_materialization_sequence);
        while (cursor.next(self.deps.blocks) catch {
            for (self.entries, 0..) |*entry, slot| {
                self.releaseMasks(slot);
                self.invalidate(entry);
            }
            self.observed_materialization_sequence = self.deps.blocks.materializationCursor().sequence;
            return;
        }) |event| {
            const slot = self.find(event.world, event.chunk) orelse continue;
            const resident = self.deps.blocks.materialized(event) orelse continue;
            const entry = &self.entries[slot];
            if (!entry.complete or entry.source_content_revision != resident.content_revision)
                self.rebuild(slot, resident);
        }
        self.observed_materialization_sequence = cursor.sequence;
    }

    fn consumeMutations(self: *CollisionProjection) void {
        var cursor = self.deps.blocks.mutationCursorFrom(self.observed_mutation_sequence);
        while (cursor.next(self.deps.blocks) catch {
            for (self.entries, 0..) |*entry, slot| {
                self.releaseMasks(slot);
                self.invalidate(entry);
            }
            self.observed_mutation_sequence = self.deps.blocks.mutationCursor().sequence;
            return;
        }) |mutation| {
            const slot = self.find(mutation.world, geometry.chunkForBlock(mutation.pos)) orelse continue;
            if (!self.entries[slot].complete) continue;
            const column: usize = @as(usize, @intCast(mutation.pos.x & 15)) + @as(usize, @intCast(mutation.pos.z & 15)) * 16;
            const force_exact = fluidState(mutation.previous_state) or fluidState(mutation.block_state) or
                mutation.pos.y >= self.heights[slot * 256 + column];
            self.setProjectedState(slot, block_store.sectionIndexForY(mutation.pos.y) orelse continue, block_store.localBlockIndexForPosition(mutation.pos), mutation.block_state, force_exact);
            self.entries[slot].source_content_revision = 0;
            self.bumpProjectionRevision(&self.entries[slot]);
            self.updateProjectedSurface(slot, @intCast(mutation.pos.x & 15), @intCast(mutation.pos.z & 15));
        }
        self.observed_mutation_sequence = cursor.sequence;
    }

    fn rebuild(self: *CollisionProjection, slot: usize, resident: *const block_store.MaterializedChunk) void {
        self.releaseMasks(slot);
        self.entries[slot].exception_count = 0;
        self.entries[slot].fluid_span_count = 0;
        self.entries[slot].complete = true;
        self.entries[slot].source_content_revision = resident.content_revision;
        self.bumpProjectionRevision(&self.entries[slot]);
        @memcpy(self.heights[slot * 256 ..][0..256], &resident.heights);
        @memset(self.grass_surfaces[slot * 4 ..][0..4], 0);
        for (0..16) |z| for (0..16) |x| self.updateSurface(slot, resident, x, z);
        var fluid_sections: u32 = 0;
        for (0..world_limits.section_count) |section| {
            if (self.deps.blocks.uniformSectionState(resident.world, resident.chunk, section)) |state| {
                if (fluidState(state)) fluid_sections |= @as(u32, 1) << @intCast(section);
                const shapes = collision.shapeBoxes(state);
                const full = shapes.len == 1 and shapes[0].min_x == 0 and shapes[0].min_y == 0 and shapes[0].min_z == 0 and
                    shapes[0].max_x == 64 and shapes[0].max_y == 64 and shapes[0].max_z == 64;
                if ((full or shapes.len == 0) and !registry.isLeafSupport(state) and !requiresExactState(state)) {
                    self.collision_handles[slot * world_limits.section_count + section] = if (full) full_mask else empty_mask;
                    self.flammable_handles[slot * world_limits.section_count + section] = if (registry.blockBehaviorFlags(state).flammable) full_mask else empty_mask;
                    continue;
                }
            }
            const encoded = resident.modified_section_indices[section];
            const modified: ?usize = if (encoded == block_store.no_modified_section_index) null else encoded;
            for (0..block_store.blocks_per_section) |raw_local| {
                const local: u16 = @intCast(raw_local);
                const state = self.deps.blocks.sectionBlockState(resident, section, local, modified);
                if (fluidState(state)) fluid_sections |= @as(u32, 1) << @intCast(section);
                self.setProjectedState(slot, section, local, state, false);
                if (!self.entries[slot].complete) return;
            }
            self.compactMask(self.collision_handles, self.collision_masks, &self.free_collision_masks, &self.free_collision_mask_count, slot, section, true);
            self.compactMask(self.flammable_handles, self.flammable_masks, &self.free_flammable_masks, &self.free_flammable_mask_count, slot, section, false);
        }
        self.rebuildFluids(slot, resident, fluid_sections);
    }

    fn invalidate(self: *CollisionProjection, entry: *Entry) void {
        entry.complete = false;
        entry.source_content_revision = 0;
        self.bumpProjectionRevision(entry);
    }

    fn bumpProjectionRevision(self: *CollisionProjection, entry: *Entry) void {
        if (self.next_projection_revision == std.math.maxInt(u64))
            std.debug.panic("collision projection revision exhausted", .{});
        entry.projection_revision = self.next_projection_revision;
        self.next_projection_revision += 1;
    }

    fn updateSurface(self: *CollisionProjection, slot: usize, resident: *const block_store.MaterializedChunk, x: usize, z: usize) void {
        const column = z * 16 + x;
        const height = resident.heights[column];
        self.heights[slot * 256 + column] = height;
        const pos = geometry.BlockPos{ .x = resident.chunk.x * 16 + @as(i32, @intCast(x)), .y = height, .z = resident.chunk.z * 16 + @as(i32, @intCast(z)) };
        const state = self.deps.blocks.blockAtMaterialized(resident, pos);
        const grass = state == registry.block_grass_block_default_state;
        self.surface_states[slot * 256 + column] = state;
        const bit = @as(u64, 1) << @intCast(column & 63);
        if (grass)
            self.grass_surfaces[slot * 4 + column / 64] |= bit
        else
            self.grass_surfaces[slot * 4 + column / 64] &= ~bit;
    }

    fn rebuildFluids(self: *CollisionProjection, slot: usize, resident: *const block_store.MaterializedChunk, fluid_sections: u32) void {
        if (fluid_sections == 0) return;
        const entry = &self.entries[slot];
        for (0..256) |column| {
            var open: ?FluidSpan = null;
            var y: i32 = world_limits.min_y;
            while (y <= block_store.world_top_y) : (y += 1) {
                const pos = geometry.BlockPos{
                    .x = resident.chunk.x * 16 + @as(i32, @intCast(column & 15)),
                    .y = @intCast(y),
                    .z = resident.chunk.z * 16 + @as(i32, @intCast(column >> 4)),
                };
                const section = block_store.sectionIndexForY(pos.y).?;
                if (fluid_sections & (@as(u32, 1) << @intCast(section)) == 0) {
                    if (open) |span| if (!self.appendFluidSpan(slot, span)) return;
                    open = null;
                    y = world_limits.min_y + @as(i32, @intCast((section + 1) * 16)) - 1;
                    continue;
                }
                const encoded = resident.modified_section_indices[section];
                const modified: ?usize = if (encoded == block_store.no_modified_section_index) null else encoded;
                const state = self.deps.blocks.sectionBlockState(resident, section, block_store.localBlockIndexForPosition(pos), modified);
                if (fluidState(state)) {
                    if (open) |*span| {
                        if (span.block_state == state) {
                            span.max_y = pos.y;
                            continue;
                        }
                        if (!self.appendFluidSpan(slot, span.*)) return;
                    }
                    open = .{ .column = @intCast(column), .min_y = pos.y, .max_y = pos.y, .block_state = state };
                } else if (open) |span| {
                    if (!self.appendFluidSpan(slot, span)) return;
                    open = null;
                }
            }
            if (open) |span| if (!self.appendFluidSpan(slot, span)) return;
            if (!entry.complete) return;
        }
    }

    fn appendFluidSpan(self: *CollisionProjection, slot: usize, span: FluidSpan) bool {
        const entry = &self.entries[slot];
        if (entry.fluid_span_count == self.fluid_spans_per_chunk) {
            entry.complete = false;
            return false;
        }
        self.fluid_spans[slot * self.fluid_spans_per_chunk + entry.fluid_span_count] = span;
        entry.fluid_span_count += 1;
        return true;
    }

    fn updateProjectedSurface(self: *CollisionProjection, slot: usize, x: usize, z: usize) void {
        const entry = &self.entries[slot];
        const column = z * 16 + x;
        var y: i32 = block_store.world_top_y;
        while (y >= world_limits.min_y) : (y -= 1) {
            const state = self.blockState(entry.world, .{
                .x = entry.chunk.x * 16 + @as(i32, @intCast(x)),
                .y = @intCast(y),
                .z = entry.chunk.z * 16 + @as(i32, @intCast(z)),
            }) orelse return;
            if (state == registry.block_air_default_state) continue;
            self.heights[slot * 256 + column] = @intCast(y);
            self.surface_states[slot * 256 + column] = state;
            const bit = @as(u64, 1) << @intCast(column & 63);
            if (state == registry.block_grass_block_default_state)
                self.grass_surfaces[slot * 4 + column / 64] |= bit
            else
                self.grass_surfaces[slot * 4 + column / 64] &= ~bit;
            return;
        }
    }

    fn fluidState(state: i32) bool {
        return (state >= registry.state_water_level_0 and state <= registry.state_water_level_15) or
            (state >= registry.state_lava_level_0 and state <= registry.state_lava_level_15);
    }

    fn setProjectedState(self: *CollisionProjection, slot: usize, section: usize, local: u16, state: i32, force_exact: bool) void {
        const position_index: u32 = @intCast(section * block_store.blocks_per_section + local);
        const shapes = collision.shapeBoxes(state);
        const full = shapes.len == 1 and shapes[0].min_x == 0 and shapes[0].min_y == 0 and shapes[0].min_z == 0 and
            shapes[0].max_x == 64 and shapes[0].max_y == 64 and shapes[0].max_z == 64;
        if (!self.setMaskBit(self.collision_handles, self.collision_masks, &self.free_collision_masks, &self.free_collision_mask_count, slot, section, local, full) or
            !self.setMaskBit(self.flammable_handles, self.flammable_masks, &self.free_flammable_masks, &self.free_flammable_mask_count, slot, section, local, registry.blockBehaviorFlags(state).flammable))
        {
            self.entries[slot].complete = false;
            return;
        }

        const base = slot * self.exceptions_per_chunk;
        const entry = &self.entries[slot];
        var found: ?usize = null;
        for (self.exception_positions[base..][0..entry.exception_count], 0..) |position, index|
            if (position == position_index) {
                found = index;
                break;
            };
        const exceptional = force_exact or (!full and shapes.len != 0) or registry.isLeafSupport(state) or requiresExactState(state);
        if (exceptional) {
            if (found) |index| {
                self.exception_states[base + index] = state;
                return;
            }
            if (entry.exception_count == self.exceptions_per_chunk) {
                entry.complete = false;
                return;
            }
            self.exception_positions[base + entry.exception_count] = position_index;
            self.exception_states[base + entry.exception_count] = state;
            entry.exception_count += 1;
        } else if (found) |index| {
            entry.exception_count -= 1;
            self.exception_positions[base + index] = self.exception_positions[base + entry.exception_count];
            self.exception_states[base + index] = self.exception_states[base + entry.exception_count];
        }
    }

    fn requiresExactState(state: i32) bool {
        if (state < 0 or state >= registry.block_state_to_block.len) return false;
        return switch (registry.block_state_to_block[@intCast(state)]) {
            registry.block_crafting_table_id,
            registry.block_chest_id,
            registry.block_furnace_id,
            => true,
            else => false,
        };
    }

    fn maskBit(self: *const CollisionProjection, handles: []const u16, masks: []const [words_per_section]u64, slot: usize, section: usize, local: u16) bool {
        _ = self;
        const handle = handles[slot * world_limits.section_count + section];
        if (handle == empty_mask) return false;
        if (handle == full_mask) return true;
        return masks[handle - 1][local / 64] & (@as(u64, 1) << @intCast(local & 63)) != 0;
    }

    fn setMaskBit(
        self: *CollisionProjection,
        handles: []u16,
        masks: [][words_per_section]u64,
        free: *[]u16,
        free_count: *usize,
        slot: usize,
        section: usize,
        local: u16,
        value: bool,
    ) bool {
        _ = self;
        const encoded = &handles[slot * world_limits.section_count + section];
        if ((encoded.* == empty_mask and !value) or (encoded.* == full_mask and value)) return true;
        if (encoded.* == empty_mask or encoded.* == full_mask) {
            if (free_count.* == 0) return false;
            free_count.* -= 1;
            const handle = free.*[free_count.*];
            @memset(&masks[handle], if (encoded.* == full_mask) std.math.maxInt(u64) else 0);
            encoded.* = handle + 1;
        }
        const word = &masks[encoded.* - 1][local / 64];
        const bit = @as(u64, 1) << @intCast(local & 63);
        if (value) word.* |= bit else word.* &= ~bit;
        return true;
    }

    fn compactMask(
        self: *CollisionProjection,
        handles: []u16,
        masks: [][words_per_section]u64,
        free: *[]u16,
        free_count: *usize,
        slot: usize,
        section: usize,
        allow_full: bool,
    ) void {
        _ = self;
        const encoded = &handles[slot * world_limits.section_count + section];
        if (encoded.* == empty_mask or encoded.* == full_mask) return;
        const page = &masks[encoded.* - 1];
        var all_empty = true;
        var all_full = allow_full;
        for (page) |word| {
            all_empty = all_empty and word == 0;
            all_full = all_full and word == std.math.maxInt(u64);
        }
        if (!all_empty and !all_full) return;
        free.*[free_count.*] = encoded.* - 1;
        free_count.* += 1;
        encoded.* = if (all_full) full_mask else empty_mask;
    }

    fn releaseMasks(self: *CollisionProjection, slot: usize) void {
        for (0..world_limits.section_count) |section| {
            self.releaseMask(self.collision_handles, &self.free_collision_masks, &self.free_collision_mask_count, slot, section);
            self.releaseMask(self.flammable_handles, &self.free_flammable_masks, &self.free_flammable_mask_count, slot, section);
        }
    }

    fn releaseMask(self: *CollisionProjection, handles: []u16, free: *[]u16, free_count: *usize, slot: usize, section: usize) void {
        _ = self;
        const encoded = &handles[slot * world_limits.section_count + section];
        if (encoded.* != empty_mask and encoded.* != full_mask) {
            free.*[free_count.*] = encoded.* - 1;
            free_count.* += 1;
        }
        encoded.* = empty_mask;
    }

    fn freeOrOldest(self: *const CollisionProjection) usize {
        var oldest: usize = 0;
        for (self.entries, 0..) |entry, slot| {
            if (!entry.valid) return slot;
            if (entry.last_used_tick < self.entries[oldest].last_used_tick) oldest = slot;
        }
        return oldest;
    }

    fn hash(world: world_identity.Handle, chunk: geometry.ChunkPos) usize {
        var value: u64 = @as(u32, @bitCast(world));
        value *%= 0xa0761d6478bd642f;
        value ^= @as(u32, @bitCast(chunk.x));
        value *%= 0xe7037ed1a0b428db;
        value ^= @as(u32, @bitCast(chunk.z));
        return @intCast(value ^ (value >> 32));
    }

    fn find(self: *const CollisionProjection, world: world_identity.Handle, chunk: geometry.ChunkPos) ?usize {
        const mask = self.lookup.len - 1;
        var index = hash(world, chunk) & mask;
        for (0..self.lookup.len) |_| {
            const encoded = self.lookup[index];
            if (encoded == 0) return null;
            const slot = encoded - 1;
            const entry = self.entries[slot];
            if (entry.world.eql(world) and geometry.sameChunk(entry.chunk, chunk)) return slot;
            index = (index + 1) & mask;
        }
        return null;
    }

    fn insert(self: *CollisionProjection, slot: usize) void {
        const mask = self.lookup.len - 1;
        var index = hash(self.entries[slot].world, self.entries[slot].chunk) & mask;
        while (self.lookup[index] != 0) index = (index + 1) & mask;
        self.lookup[index] = @intCast(slot + 1);
    }

    fn remove(self: *CollisionProjection, slot: usize) void {
        const mask = self.lookup.len - 1;
        var index = hash(self.entries[slot].world, self.entries[slot].chunk) & mask;
        for (0..self.lookup.len) |_| {
            if (self.lookup[index] == slot + 1) break;
            std.debug.assert(self.lookup[index] != 0);
            index = (index + 1) & mask;
        } else unreachable;
        self.releaseMasks(slot);
        self.lookup[index] = 0;
        var next = (index + 1) & mask;
        while (self.lookup[next] != 0) {
            const displaced = self.lookup[next] - 1;
            self.lookup[next] = 0;
            self.insert(displaced);
            next = (next + 1) & mask;
        }
        self.entries[slot] = .{};
    }
};
