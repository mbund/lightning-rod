const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const std = @import("std");
const chunks = @import("chunks");
const game_data = @import("game_data");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const support = @import("protocol_support");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_26_1 = @import("wire_26_1");
const lightning_rod = @import("lightning_rod");
const lighting = @import("lighting.zig");
const worlds = @import("worlds");
const assert = std.debug.assert;
const container_blocks = @import("container_blocks.zig");

pub const Workspace = struct {
    const Summary = struct {
        const State = struct {
            stamp: lighting.Stamp = .{ .generation = std.math.maxInt(u64) },
            palette_len: u16 = 0,
            count: u16 = 0,
            fluid_count: u16 = 0,
            block_entities: u16 = 0,
            direct: bool = false,
        };

        state: State = .{},
        heights: [256]u8 = undefined,
        palette: [256]u16 = undefined,

        fn reset(self: *Summary) void {
            self.state = .{};
        }
    };

    const Column = struct {
        valid: bool = false,
        stamps: [lighting.maximum_sections]lighting.Stamp = undefined,
        count: usize = 0,
        minimum_section: i32 = 0,
        heights: [256]i16 = undefined,
        heightmap: [37]u64 = undefined,
    };

    column: Column = .{},
    summaries: [lighting.maximum_sections]Summary = @splat(.{}),
    palette_indices: [1 << game_data.registry.block_state_bits]u16 = @splat(std.math.maxInt(u16)),

    pub fn init(allocator: std.mem.Allocator) !*Workspace {
        const self = try allocator.create(Workspace);
        errdefer allocator.destroy(self);
        self.* = .{};
        return self;
    }

    fn prepare(self: *Workspace, sections: []const lighting.Section) !void {
        assert(sections.len <= self.summaries.len);
        for (sections, 0..) |section, index| {
            const summary = &self.summaries[index];
            if (std.meta.eql(summary.state.stamp, section.stamp)) continue;
            summary.reset();
            const view = section.view;
            defer {
                for (summary.palette[0..summary.state.palette_len]) |state| self.palette_indices[state] = std.math.maxInt(u16);
            }
            if (view == .uniform) {
                const state = view.uniform;
                if (state >= self.palette_indices.len) return error.InvalidBlockState;
                summary.palette[0] = state;
                summary.state.palette_len = 1;
                summary.state.count = if (state != 0) 4096 else 0;
                summary.state.block_entities = if (container_blocks.entityName(state) != null) 4096 else 0;
                summary.state.fluid_count = if (game_data.registry.stateContainsFluid(state)) 4096 else 0;
                @memset(&summary.heights, if (state != 0) 16 else 0);
            } else {
                @memset(&summary.heights, 0);
                for (0..4096) |i| {
                    const state = view.get(@intCast(i));
                    if (state >= self.palette_indices.len) return error.InvalidBlockState;
                    if (state != 0) {
                        summary.state.count += 1;
                        summary.heights[i % 256] = @intCast(i / 256 + 1);
                    }
                    summary.state.block_entities += @intFromBool(container_blocks.entityName(state) != null);
                    summary.state.fluid_count += @intFromBool(game_data.registry.stateContainsFluid(state));
                    if (summary.state.direct or self.palette_indices[state] != std.math.maxInt(u16)) continue;
                    if (summary.state.palette_len == summary.palette.len) {
                        summary.state.direct = true;
                        continue;
                    }
                    self.palette_indices[state] = summary.state.palette_len;
                    summary.palette[summary.state.palette_len] = state;
                    summary.state.palette_len += 1;
                }
            }
            summary.state.stamp = section.stamp;
        }
    }

    fn prepareColumn(self: *Workspace, chunk: Chunk) *const Column {
        const column = &self.column;
        var matches = column.valid and column.count == chunk.sections.len and column.minimum_section == chunk.minimum_section;
        for (chunk.sections, 0..) |section, i| {
            const stamp = section.stamp;
            matches = matches and std.meta.eql(column.stamps[i], stamp);
            column.stamps[i] = stamp;
        }
        if (matches) return column;
        column.count = chunk.sections.len;
        column.minimum_section = chunk.minimum_section;
        const minimum_y: i16 = @intCast(chunk.minimum_section * 16);
        @memset(&column.heights, minimum_y - 1);
        for (chunk.sections, 0..) |section, s| {
            const view = section.view;
            if (view == .uniform) {
                if (view.uniform != 0) @memset(&column.heights, @as(i16, @intCast(s * 16 + 15)) + minimum_y);
                continue;
            }
            const summary = &self.summaries[s];
            for (summary.heights, &column.heights) |height, *height_column| {
                if (height != 0) height_column.* = @as(i16, @intCast(s * 16 + height - 1)) + minimum_y;
            }
        }
        @memset(&column.heightmap, 0);
        for (column.heights, 0..) |height, i| {
            column.heightmap[i / 7] |= @as(u64, @intCast(height - minimum_y + 1)) << @intCast((i % 7) * 9);
        }
        column.valid = true;
        return column;
    }
};

pub const Chunk = struct {
    x: i32,
    z: i32,
    sections: []const lighting.Section,
    biome: i32,
    minimum_section: i32,
    workspace: *Workspace,
    light: lighting.Data,
};

pub const write = .{ writeLegacy, writeFluidCount };

fn writeLegacy(packet: wire_1_21_5.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, chunk: Chunk, protocol: *const sessions.Protocol) ![]u8 {
    return encode(packet._cursor, registry, chunk, protocol, false);
}

fn writeFluidCount(packet: wire_26_1.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, chunk: Chunk, protocol: *const sessions.Protocol) ![]u8 {
    return encode(packet._cursor, registry, chunk, protocol, true);
}

// The schema exposes chunkData as opaque bytes, so section encoding must handle the 26.1 fluid count.
fn encode(cursor: support.cursor.State(.write), registry: packets.Registry, chunk: Chunk, protocol: *const sessions.Protocol, comptime write_fluid_count: bool) ![]u8 {
    const x = chunk.x;
    const z = chunk.z;
    const sections = chunk.sections;
    assert(chunk.light.count == sections.len + 2);
    const biome = chunk.biome;
    if (biome < 0 or biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
    const biome_name = game_data.registry.biome_names[@intCast(biome)];
    const wire_biome = try protocol.registryId("minecraft:worldgen/biome", biome_name);
    const output = cursor.buffer;
    var writer: std.Io.Writer = .fixed(output);
    writer.end = output.len - cursor.rest.len;
    try writer.writeInt(i32, x, .big);
    try writer.writeInt(i32, z, .big);
    const workspace = chunk.workspace;
    try workspace.prepare(sections);
    const column = workspace.prepareColumn(chunk);
    try varint(&writer, 2);

    for ([_]i32{ 1, 4 }) |kind| {
        try varint(&writer, kind);
        try varint(&writer, 37);

        for (column.heightmap) |word| try writer.writeInt(u64, word, .big);
    }

    const length_offset = writer.end;
    try writer.splatByteAll(0, 3);
    const palette_indices = &workspace.palette_indices;

    for (sections, 0..) |snapshot, section_index| {
        const section = snapshot.view;
        const summary = &workspace.summaries[section_index];
        const first = section.get(0);
        const count = summary.state.count;
        const fluid_count = summary.state.fluid_count;
        const palette_len: usize = summary.state.palette_len;
        const palette = &summary.palette;
        const direct = summary.state.direct;
        for (palette[0..palette_len], 0..) |state, index| palette_indices[state] = @intCast(index);
        defer {
            for (palette[0..palette_len]) |state| palette_indices[state] = std.math.maxInt(u16);
        }

        try writer.writeInt(u16, count, .big);
        if (write_fluid_count) try writer.writeInt(u16, fluid_count, .big);

        if (palette_len == 1 and !direct) {
            try writer.writeByte(0);
            try varint(&writer, try registry.blockState(first));
        } else {
            const bits: u8 = if (direct) registry.block_state_bits else @intCast(@max(4, std.math.log2_int_ceil(usize, palette_len)));
            try writer.writeByte(bits);

            if (!direct) {
                try varint(&writer, @intCast(palette_len));

                for (palette[0..palette_len]) |state| try varint(&writer, try registry.blockState(state));
            }

            const per_word: usize = 64 / bits;

            for (0..(4096 + per_word - 1) / per_word) |word| {
                var value: u64 = 0;

                for (0..per_word) |i| {
                    const index = word * per_word + i;

                    if (index < 4096) {
                        const state = section.get(@intCast(index));
                        const encoded: u32 = if (direct) @intCast(try registry.blockState(state)) else palette_indices[state];
                        assert(direct or encoded < palette_len);
                        value |= @as(u64, encoded) << @intCast(i * bits);
                    }
                }

                try writer.writeInt(u64, value, .big);
            }
        }

        try writer.writeByte(0);
        try varint(&writer, wire_biome);
    }

    const length: u32 = @intCast(writer.end - length_offset - 3);
    output[length_offset] = @as(u8, @truncate(length & 127)) | 128;
    output[length_offset + 1] = @as(u8, @truncate((length >> 7) & 127)) | 128;
    output[length_offset + 2] = @intCast(length >> 14);
    var entities: usize = 0;
    for (workspace.summaries[0..sections.len]) |summary| entities += summary.state.block_entities;
    try varint(&writer, @intCast(entities));
    for (sections, 0..) |section, section_index| {
        if (workspace.summaries[section_index].state.block_entities == 0) continue;
        for (0..4096) |index| {
            const name = container_blocks.entityName(section.view.get(@intCast(index))) orelse continue;
            try writer.writeByte(@intCast(((index % 16) << 4) | ((index / 16) % 16)));
            try writer.writeInt(i16, @intCast((chunk.minimum_section + @as(i32, @intCast(section_index))) * 16 + @as(i32, @intCast(index / 256))), .big);
            try varint(&writer, try protocol.registryId("minecraft:block_entity_type", name));
            try writer.writeAll(&.{ 10, 0 });
        }
    }
    try chunk.light.write(&writer);
    return output[0..writer.end];
}

fn varint(writer: *std.Io.Writer, value: i32) !void {
    var number: u32 = @bitCast(value);

    while (number >= 128) : (number >>= 7) try writer.writeByte(@as(u8, @truncate(number & 127)) | 128);
    try writer.writeByte(@intCast(number));
}

test "section summaries invalidate on edits and slot reuse and recover after errors" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var metric_registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 48 });
    defer metric_registry.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/encoding", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const transaction = store.transaction();
    defer transaction.fail();
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .demand_sections = 1, .cache_sections = 4 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("chunks"), .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
    const workspace = try Workspace.init(arena.allocator());
    const position: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    const snapshot = try lighting.Workspace.init(arena.allocator(), terrain, try game_data.lighting.init(arena.allocator()));
    const world_dimension: worlds.Worlds.Dimension = .{ .name = "test:encoding", .minimum_section = 0, .section_count = 1, .skylight = true };
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 1 }});
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u8, 16), workspace.summaries[0].heights[255]);
    try std.testing.expectEqual(@as(u16, 2), workspace.summaries[0].state.palette_len);
    var states: [258]i32 = undefined;
    for (&states, 0..) |*state, i| state.* = @intCast(i);
    const registry: packets.Registry = .{
        .entities = &.{},
        .items = &.{},
        .blocks = &.{},
        .block_states = &states,
        .block_state_bits = game_data.registry.block_state_bits,
        .sounds = &.{},
        .effects = &.{},
        .attributes = &.{},
    };
    const protocol: sessions.Protocol = .{
        .number = 0,
        .registries = &.{.{ .name = "minecraft:worldgen/biome", .entries = &.{"minecraft:plains"} }},
    };
    var column: Chunk = .{
        .x = 0,
        .z = 0,
        .sections = snapshot.sections(),
        .biome = game_data.registry.biomeId("minecraft:plains").?,
        .minimum_section = 0,
        .workspace = workspace,
        .light = snapshot.data(),
    };
    var short: [640]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encode(.init(&short), registry, column, &protocol, true));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    var reused: [32 * 1024]u8 = undefined;
    var fresh: [32 * 1024]u8 = undefined;
    inline for (.{ false, true }) |fluid_count| {
        column.workspace = workspace;
        const actual = try encode(.init(&reused), registry, column, &protocol, fluid_count);
        column.workspace = try Workspace.init(arena.allocator());
        const expected = try encode(.init(&fresh), registry, column, &protocol, fluid_count);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    const revision = workspace.summaries[0].state.stamp;
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(revision, workspace.summaries[0].state.stamp);
    var edits: [257]chunks.BlockEdit = undefined;
    for (&edits, 0..) |*edit, i| edit.* = .{ .index = @intCast(i), .state = @intCast(i + 1) };
    try terrain.setBlocks(position, &edits);
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expect(workspace.summaries[0].state.direct);
    try std.testing.expectEqual(@as(u16, 258), workspace.summaries[0].state.count);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = std.math.maxInt(u16) }});
    try std.testing.expectError(error.InvalidEdit, prepareSnapshot(snapshot, terrain, world_dimension, 0));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 0 }});
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 257), workspace.summaries[0].state.count);
    column.sections = snapshot.sections();
    const changed = workspace.prepareColumn(column);
    try std.testing.expectEqual(@as(i16, 0), changed.heights[255]);
    try std.testing.expectEqual(@as(i16, 1), changed.heights[0]);
    column.minimum_section = -4;
    const dimension = workspace.prepareColumn(column);
    try std.testing.expectEqual(@as(i16, -63), dimension.heights[0]);

    try prepareSnapshot(snapshot, terrain, world_dimension, 1);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.palette_len);
    try std.testing.expectEqual(@as(u8, 0), workspace.summaries[0].heights[255]);
    column.sections = snapshot.sections();
    try std.testing.expectEqual(@as(i16, -65), workspace.prepareColumn(column).heights[0]);
}

fn prepareSnapshot(snapshot: *lighting.Workspace, terrain: *chunks.Chunks, dimension: worlds.Worlds.Dimension, x: i32) !void {
    for (0..128) |_| {
        if (try snapshot.prepare(terrain, 0, x, 0, dimension, 0)) return;
        try terrain.poll();
    }
    return error.SnapshotStalled;
}
