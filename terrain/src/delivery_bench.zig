//! Encodes every stored column of a prewarmed world for every protocol, as a warm delivery
//! does, so changes to delivery can be compared by instruction counts and packet bytes.
//! Usage: delivery-bench <world> [repeats] [columns]. Count instructions with perf for 1 and N repeats
//! and take the difference, which leaves out opening the world.
const std = @import("std");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocol_set = packets.protocols;
const chunk_encoding = @import("chunk_encoding.zig");
const delivery_cache = @import("delivery_cache.zig");
const test_blocks = @import("test_blocks.zig");

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const path = arguments.next() orelse return error.MissingWorld;
    const repeats = if (arguments.next()) |text| try std.fmt.parseInt(usize, text, 10) else 1;
    const limit = if (arguments.next()) |text| try std.fmt.parseInt(usize, text, 10) else std.math.maxInt(usize);
    const allocator = init.arena.allocator();
    const io = init.io;
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 128 });
    defer registry.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    const resources = try records.Workspaces.init(allocator, io, .{ .metrics = &registry });
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 1, .cache_groups = 1 }, .{ .metrics = &registry, .storage = try store.openSpace(chunks.Chunks.id), .record_workspaces = resources });
    var columns: std.ArrayList(chunks.Light.Column) = .empty;
    {
        var after: [64]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &after };
        while (true) {
            var batch: [32]chunks.Light.Column = undefined;
            const result = try terrain.savedLightColumns(&cursor, &batch);
            try columns.appendSlice(allocator, batch[0..result.count]);
            if (!result.more) break;
        }
    }
    if (columns.items.len > limit) {
        // An even sample across the world, the same one every run.
        for (0..limit) |index| columns.items[index] = columns.items[index * columns.items.len / limit];
        columns.shrinkRetainingCapacity(limit);
    }
    const table = terrain.cache.backend.store.lights;
    const stored = try allocator.alloc([]const u8, columns.items.len);
    for (columns.items, stored) |column, *bytes| {
        const key = chunks.Delivery.key(column);
        var lengths: [1]?usize = undefined;
        try table.lengthsBatch(&.{&key}, &lengths);
        const buffer = try allocator.alloc(u8, lengths[0] orelse return error.MissingColumn);
        bytes.* = buffer[0 .. (try table.get(&key, buffer)) orelse return error.MissingColumn];
    }
    var selected = try protocol_set.Default.init(allocator);
    const blocks = try test_blocks.vanilla(allocator);
    const encoder = try chunk_encoding.Workspace.init(allocator, 1 << 20, &selected.values, blocks);
    var catalog = try chunk_encoding.Workspace.initDeliveryCatalog(allocator, &selected.values);
    const cache = try delivery_cache.Workspace.init(allocator, selected.values.len);
    var frames = try chunks.Light.Workspace.init(allocator);
    const output = try allocator.alloc(u8, 1 << 21);
    var bytes: [protocol_set.implementations.len]u64 = @splat(0);
    var digest = std.hash.Wyhash.init(0);
    var records_used: u64 = 0;
    var compiled: u64 = 0;
    for (0..repeats) |_| {
        inline for (protocol_set.implementations, 0..) |Version, protocol_index| {
            const definition = for (&selected.values) |*value| {
                if (value.number == Version.protocol_number) break value;
            } else unreachable;
            const wire = packets.Registry.forVersion(Version);
            var begin: usize = 0;
            while (begin < columns.items.len) {
                const count = @min(delivery_cache.batch_max, columns.items.len - begin);
                var requests: [delivery_cache.batch_max]delivery_cache.Request = undefined;
                for (requests[0..count], columns.items[begin..][0..count]) |*request, column| request.* = .{ .column = column, .protocol = Version.protocol_number };
                _ = try cache.begin(&catalog, requests[0..count]);
                for (0..count) |slot| {
                    cache.values[slot] = stored[begin + slot];
                    cache.complete[slot] = true;
                }
                for (columns.items[begin..][0..count], stored[begin..][0..count]) |column, record| {
                    const frame = try frames.decode((try chunks.Delivery.Column.read(record)).frame);
                    const neighborhood: chunk_encoding.BiomeNeighborhood = .{ .source = .{ .baked = &frame }, .count = frame.header.count, .disclosed = frame.header.biomes };
                    const chunk: chunk_encoding.Chunk = .{
                        .world = column.world,
                        .x = column.x,
                        .z = column.z,
                        .minimum_section = frame.header.minimum,
                        .sections = .{ .baked = .{ .view = &frame } },
                        .biome = neighborhood.first() orelse 0,
                        .workspace = encoder,
                        .light = .{ .source = .{ .stored = &frame }, .count = @as(usize, frame.header.count) + 2, .masks = .{ @intCast(frame.masks[0]), @intCast(frame.masks[1]) }, .coverage = frame.header.coverage },
                    };
                    const prepared = try encoder.prepareDelivery(cache, chunk, Version.protocol_number);
                    const packet = try sessions.packet_api.encode(Version, chunk_encoding.write_delivery, output, .{ wire, &prepared, definition });
                    bytes[protocol_index] += packet.len;
                    records_used += @intFromBool(prepared.encoding == .record);
                    digest.update(packet);
                }
                compiled += cache.used;
                cache.cancel();
                begin += count;
            }
        }
    }
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &output_buffer);
    try writer.interface.print("columns {d}, repeats {d}, packets from records {d}, compiled bytes {d}, digest {x}\n", .{ columns.items.len, repeats, records_used, compiled, digest.final() });
    inline for (protocol_set.implementations, bytes) |Version, total| try writer.interface.print("protocol {d}: {d} bytes, {d:.1} per column\n", .{ Version.protocol_number, total, @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(columns.items.len * repeats)) });
    try writer.interface.flush();
}
