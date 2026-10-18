const storage = @import("storage");
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
const assert = std.debug.assert;

pub const Workspace = struct {
    const Summary = struct {
        const State = struct {
            generation: u64 = std.math.maxInt(u64),
            revision: u64 = 0,
            palette_len: u16 = 0,
            count: u16 = 0,
            fluid_count: u16 = 0,
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
        const Stamp = struct { index: usize, generation: u64, revision: u64 };
        valid: bool = false,
        stamps: [24]Stamp = undefined,
        count: usize = 0,
        minimum_section: i32 = 0,
        skylight: bool = false,
        heights: [256]i16 = undefined,
        heightmap: [37]u64 = undefined,
        sky_mask: u32 = 0,
        light: [26][2048]u8 = undefined,
    };

    column: Column = .{},
    summaries: []Summary,
    palette_indices: [1 << game_data.registry.block_state_bits]u16 = @splat(std.math.maxInt(u16)),

    pub fn init(allocator: std.mem.Allocator, slots: usize) !*Workspace {
        const self = try allocator.create(Workspace);
        errdefer allocator.destroy(self);
        self.* = try Workspace.initValue(allocator, slots);
        return self;
    }

    fn initValue(allocator: std.mem.Allocator, slots: usize) !Workspace {
        const summaries = try allocator.alloc(Summary, slots);
        for (summaries) |*summary| summary.* = .{};
        return .{ .summaries = summaries };
    }

    fn prepare(self: *Workspace, sections: []const chunks.Lease) !void {
        for (sections) |lease| {
            const summary = &self.summaries[lease.record.index];
            const revision = lease.record.revision();
            if (summary.state.generation == lease.record.generation and summary.state.revision == revision) continue;
            summary.reset();
            const view = lease.view();
            defer {
                for (summary.palette[0..summary.state.palette_len]) |state| self.palette_indices[state] = std.math.maxInt(u16);
            }
            if (view == .uniform) {
                const state = view.uniform;
                if (state >= self.palette_indices.len) return error.InvalidBlockState;
                summary.palette[0] = state;
                summary.state.palette_len = 1;
                summary.state.count = if (state != 0) 4096 else 0;
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
            summary.state.revision = revision;
            summary.state.generation = lease.record.generation;
        }
    }

    fn prepareColumn(self: *Workspace, chunk: Chunk) *const Column {
        const column = &self.column;
        var matches = column.valid and column.count == chunk.sections.len and column.minimum_section == chunk.minimum_section and column.skylight == chunk.skylight;
        for (chunk.sections, 0..) |lease, i| {
            const stamp: Column.Stamp = .{ .index = lease.record.index, .generation = lease.record.generation, .revision = lease.record.revision() };
            matches = matches and std.meta.eql(column.stamps[i], stamp);
            column.stamps[i] = stamp;
        }
        if (matches) return column;
        column.count = chunk.sections.len;
        column.minimum_section = chunk.minimum_section;
        column.skylight = chunk.skylight;
        const minimum_y: i16 = @intCast(chunk.minimum_section * 16);
        @memset(&column.heights, minimum_y - 1);
        for (chunk.sections, 0..) |lease, s| {
            const view = lease.view();
            if (view == .uniform) {
                if (view.uniform != 0) @memset(&column.heights, @as(i16, @intCast(s * 16 + 15)) + minimum_y);
                continue;
            }
            const summary = &self.summaries[lease.record.index];
            for (summary.heights, &column.heights) |height, *height_column| {
                if (height != 0) height_column.* = @as(i16, @intCast(s * 16 + height - 1)) + minimum_y;
            }
        }
        @memset(&column.heightmap, 0);
        for (column.heights, 0..) |height, i| {
            column.heightmap[i / 7] |= @as(u64, @intCast(height - minimum_y + 1)) << @intCast((i % 7) * 9);
        }
        const minimum = std.mem.min(i16, &column.heights);
        const maximum = std.mem.max(i16, &column.heights);
        column.sky_mask = 0;
        for (0..chunk.sections.len + 2) |section| {
            const bottom = (@as(i32, @intCast(section)) + chunk.minimum_section - 1) * 16;
            if (!chunk.skylight or bottom + 15 <= minimum) continue;
            column.sky_mask |= @as(u32, 1) << @intCast(section);
            if (bottom > maximum) continue;
            for (&column.light[section], 0..) |*byte, i| {
                const y = bottom + @as(i32, @intCast(i / 128));
                byte.* = @as(u8, if (y > column.heights[(i * 2) % 256]) 15 else 0) | @as(u8, if (y > column.heights[(i * 2 + 1) % 256]) 240 else 0);
            }
        }
        column.valid = true;
        return column;
    }
};

const full_skylight: [2048]u8 = @splat(255);

pub const Chunk = struct {
    x: i32,
    z: i32,
    sections: []const chunks.Lease,
    biome: i32,
    minimum_section: i32,
    skylight: bool,
    workspace: *Workspace,
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

    for (sections) |lease| {
        const section = lease.view();
        const summary = &workspace.summaries[lease.record.index];
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
    try varint(&writer, 0);
    const sky_mask = column.sky_mask;
    const maximum = std.mem.max(i16, &column.heights);
    const light_sections = sections.len + 2;
    const light_mask = (@as(u64, 1) << @intCast(light_sections)) - 1;

    try varint(&writer, 1);
    try writer.writeInt(u64, sky_mask, .big);
    try varint(&writer, 0);
    try varint(&writer, 1);
    try writer.writeInt(u64, (~@as(u64, sky_mask)) & light_mask, .big);
    try varint(&writer, 1);
    try writer.writeInt(u64, light_mask, .big);
    try varint(&writer, @popCount(sky_mask));

    for (0..light_sections) |section| {
        if (sky_mask & (@as(u32, 1) << @intCast(section)) == 0) continue;
        try varint(&writer, 2048);
        const light = try writer.writableSlice(2048);
        if ((@as(i32, @intCast(section)) + chunk.minimum_section - 1) * 16 > maximum) {
            @memcpy(light, &full_skylight);
            continue;
        }

        @memcpy(light, &column.light[section]);
    }

    try varint(&writer, 0);
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
    var metric_registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
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
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .cache_sections = 1 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("chunks") });
    const workspace = try Workspace.init(arena.allocator(), 1);
    const position: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    var lease = try terrain.acquire(position);
    try workspace.prepare(&.{lease});
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    lease.release();
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 1 }});
    lease = try terrain.acquire(position);
    try workspace.prepare(&.{lease});
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
        .sections = &.{lease},
        .biome = game_data.registry.biomeId("minecraft:plains").?,
        .minimum_section = 0,
        .skylight = true,
        .workspace = workspace,
    };
    var short: [640]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encode(.init(&short), registry, column, &protocol, true));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    var reused: [32 * 1024]u8 = undefined;
    var fresh: [32 * 1024]u8 = undefined;
    inline for (.{ false, true }) |fluid_count| {
        column.workspace = workspace;
        const actual = try encode(.init(&reused), registry, column, &protocol, fluid_count);
        column.workspace = try Workspace.init(arena.allocator(), 1);
        const expected = try encode(.init(&fresh), registry, column, &protocol, fluid_count);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    const revision = workspace.summaries[0].state.revision;
    try workspace.prepare(&.{lease});
    try std.testing.expectEqual(revision, workspace.summaries[0].state.revision);
    lease.release();
    var edits: [257]chunks.BlockEdit = undefined;
    for (&edits, 0..) |*edit, i| edit.* = .{ .index = @intCast(i), .state = @intCast(i + 1) };
    try terrain.setBlocks(position, &edits);
    lease = try terrain.acquire(position);
    try workspace.prepare(&.{lease});
    try std.testing.expect(workspace.summaries[0].state.direct);
    try std.testing.expectEqual(@as(u16, 258), workspace.summaries[0].state.count);
    lease.release();
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = std.math.maxInt(u16) }});
    lease = try terrain.acquire(position);
    try std.testing.expectError(error.InvalidBlockState, workspace.prepare(&.{lease}));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    lease.release();
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 0 }});
    lease = try terrain.acquire(position);
    try workspace.prepare(&.{lease});
    try std.testing.expectEqual(@as(u16, 257), workspace.summaries[0].state.count);
    const changed = workspace.prepareColumn(column);
    try std.testing.expectEqual(@as(i16, 0), changed.heights[255]);
    try std.testing.expectEqual(@as(i16, 1), changed.heights[0]);
    column.minimum_section = -4;
    column.skylight = false;
    const dimension = workspace.prepareColumn(column);
    try std.testing.expectEqual(@as(i16, -63), dimension.heights[0]);
    try std.testing.expectEqual(@as(u32, 0), dimension.sky_mask);
    lease.release();
    lease = try terrain.acquire(.{ .world = 0, .x = 1, .y = 0, .z = 0 });
    defer lease.release();
    try workspace.prepare(&.{lease});
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.palette_len);
    try std.testing.expectEqual(@as(u8, 0), workspace.summaries[0].heights[255]);
    column.sections = &.{lease};
    try std.testing.expectEqual(@as(i16, -65), workspace.prepareColumn(column).heights[0]);
}
