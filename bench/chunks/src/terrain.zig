const std = @import("std");
const records = @import("records");
const chunks = @import("chunks");
const storage = @import("storage");
const metrics = @import("metrics");
const corpus = @import("corpus.zig");
const common = @import("common.zig");

pub const seed_columns = 128;

pub fn acquireColumns(reader: chunks.Chunks.Client, source: *const corpus.Corpus, ids: []const u32) !void {
    var start: usize = 0;
    while (start < ids.len) {
        const count: usize = @min(8, ids.len - start);
        var sections: [192]chunks.Section = undefined;
        var leases: [192]chunks.Lease = undefined;
        for (ids[start..][0..count], 0..) |id, index| {
            const column = source.columns[id];
            for (0..corpus.section_count) |y| sections[index * corpus.section_count + y] = .{ .world = 0, .x = column.x, .z = column.z, .y = @as(i32, @intCast(y)) + corpus.minimum_y };
        }
        const n = count * corpus.section_count;
        try reader.acquireMany(sections[0..n], leases[0..n]);
        for (leases[0..n]) |lease| lease.release();
        start += count;
    }
}

pub const Seed = struct { wal_bytes: u64, maintenance_bytes: u64 };

pub fn seedDatabase(init: std.process.Init, source: *corpus.Corpus, path: []const u8) !Seed {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var registry = try metrics.Registry.init(init.gpa, init.io, .{ .capacity = 128 });
    defer registry.deinit();
    try common.removeDatabase(init.gpa, init.io, path);
    var store = try storage.Store.init(init.gpa, init.io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    const space = try store.openSpace(chunks.Chunks.id);
    const world = try chunks.Chunks.init(arena.allocator(), init.io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 193 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), init.io, .{}) });
    const reader = try world.client(.{ .name = "bench", .sections = 192 });
    world.setSource(chunks.Source.init(source, corpus.Corpus.read));
    var ids: [seed_columns]u32 = undefined;
    var start: usize = 0;
    var tick: u64 = 0;
    while (start < source.columns.len) {
        const count = @min(ids.len, source.columns.len - start);
        for (ids[0..count], 0..) |*id, index| id.* = @intCast(start + index);
        try acquireColumns(reader, source, ids[0..count]);
        try world.checkpoint(space);
        tick += 1;
        try store.waitDurable(try store.commit(tick));
        try common.drain(&store);
        start += count;
    }
    std.debug.print("Seeded {d} columns ({d} source columns, {d} copies), database {d} bytes\n", .{ source.columns.len, source.columns.len / source.copies, source.copies, (try store.database.stat(init.io)).size });
    return .{ .wal_bytes = store.wal_bytes.value(), .maintenance_bytes = store.checkpoint_bytes.value() };
}
