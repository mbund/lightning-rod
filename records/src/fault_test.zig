const std = @import("std");
const records = @import("records");
const storage = @import("storage");
const fault = @import("fault_disk");
const structure = @import("structure_test.zig");

const count = 32;

fn length(tick: u64, id: usize) ?usize {
    return switch (tick) {
        1 => 519,
        2 => if (id % 2 == 0) 6000 else null,
        3 => 3,
        else => unreachable,
    };
}

fn change(store: *storage.Store, table_resources: *records.Resources, tick: u64) !void {
    const table = records.Table.init(try store.openSpace("records"), table_resources);
    var keys: [count][2]u8 = undefined;
    var writes: [count]records.Write = undefined;
    const value: [8193]u8 = @splat(@intCast(tick));
    for (&keys, &writes, 0..) |*key, *write, id| {
        std.mem.writeInt(u16, key, @intCast(id), .big);
        write.* = .{ .key = key, .value = if (length(tick, id)) |size| value[0..size] else null };
    }
    try table.putBatch(&writes);
    _ = try store.commit(tick);
}

fn scenario(store: *storage.Store, table_resources: *records.Resources, acknowledged: *u64) !void {
    try change(store, table_resources, 2);
    try store.waitDurable(store.lastCommit());
    acknowledged.* = 2;
    _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
    while (store.phase != .database_sync) _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
    try change(store, table_resources, 3);
}

test "power loss during tree balancing and overflow reuse preserves a complete save" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try change(&store, table_resources, 1);
        try store.waitDurable(store.lastCommit());
    }
    for ([_]bool{ false, true }) |short| {
        var events: usize = 0;
        {
            var store = try storage.Store.init(std.testing.allocator, io, options);
            var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), short);
            defer disk.deinit();
            const modeled = disk.interface();
            store.io = modeled;
            store.filesystem.io = modeled;
            store.maintenance_io.io = modeled;
            var acknowledged: u64 = 1;
            try scenario(&store, table_resources, &acknowledged);
            events = disk.events;
            store.deinit();
            disk.detach();
        }
        try std.testing.expect(events != 0);
        for (1..events + 1) |cut| {
            for (std.enums.values(fault.Disk.Mode)) |mode| {
                errdefer std.debug.print("record power loss short={} cut={d}/{d} mode={t}\n", .{ short, cut, events, mode });
                var store = try storage.Store.init(std.testing.allocator, io, options);
                var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, cut, short);
                defer disk.deinit();
                const modeled = disk.interface();
                store.io = modeled;
                store.filesystem.io = modeled;
                store.maintenance_io.io = modeled;
                var acknowledged: u64 = 1;
                scenario(&store, table_resources, &acknowledged) catch |err| switch (err) {
                    error.IoFailure, error.FailedTransaction, error.NoSpace => {},
                    else => return err,
                };
                store.deinit();
                disk.detach();
                disk.crash(mode);
                disk.cut = std.math.maxInt(usize);
                disk.failed = false;
                var recovered = try storage.Store.init(std.testing.allocator, disk.interface(), options);
                defer {
                    recovered.deinit();
                    disk.detach();
                }
                const tick = recovered.lastTick();
                try std.testing.expect(tick >= acknowledged and tick <= 3);
                const table = records.Table.init(try recovered.openSpace("records"), table_resources);
                _ = try structure.inspect(table);
                var value: [8193]u8 = undefined;
                for (0..count) |id| {
                    var key: [2]u8 = undefined;
                    std.mem.writeInt(u16, &key, @intCast(id), .big);
                    const expected = length(tick, id);
                    try std.testing.expectEqual(expected, try table.get(&key, &value));
                    for (value[0 .. expected orelse 0]) |byte| try std.testing.expectEqual(@as(u8, @intCast(tick)), byte);
                }
            }
        }
    }
}
