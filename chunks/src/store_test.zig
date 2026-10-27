const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const fault = @import("fault_disk");
const chunks = @import("chunks.zig");
const encoding = @import("encoding.zig");
const ChunkStore = @import("store.zig").Store;

const count = 12;

fn keyFor(id: usize) [16]u8 {
    var key: [16]u8 = undefined;
    std.mem.writeInt(u32, key[0..4], @intCast(id / 4), .big);
    std.mem.writeInt(i32, key[4..8], -2 + @as(i32, @intCast(id % 4 / 2)), .big);
    std.mem.writeInt(i32, key[8..12], -2 + @as(i32, @intCast(id % 2)), .big);
    std.mem.writeInt(i32, key[12..16], @as(i32, @intCast(id / 8)) - 4, .big);
    return key;
}

fn valueFor(tick: u64, id: usize, output: []u8) ?[]const u8 {
    if ((tick == 2 and id % 3 == 0) or tick == 4) return null;
    const states: usize = if (tick == 1) 1279 else if (tick == 2) 5 else 1;
    var dense: [8193]u8 = undefined;
    dense[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, dense[1 + index * 2 ..][0..2], @intCast(index % states + id * 1280), .little);
    const encoded = encoding.encode(&dense, output) catch unreachable;
    if (encoded.ptr != output.ptr) @memcpy(output[0..encoded.len], encoded);
    return output[0..encoded.len];
}

fn change(store: *storage.Store, tick: u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, store.io, .{ .capacity = 16 });
    defer registry.deinit();
    var chunks_store = try ChunkStore.init(arena.allocator(), store.io, try store.openSpace(chunks.Chunks.id), 2, &registry, try records.Resources.init(arena.allocator(), store.io, .{ .readers = 1, .writers = 1 }));
    var keys: [count][16]u8 = undefined;
    var values: [count][8193]u8 = undefined;
    var writes: [count]records.Write = undefined;
    for (&keys, &values, &writes, 0..) |*key, *value, *write, id| {
        key.* = keyFor(id);
        write.* = .{ .key = key, .value = valueFor(tick, id, value) };
    }
    try chunks_store.putBatch(&writes);
    try chunks_store.flush();
    _ = try store.commit(tick);
}

fn verify(store: *storage.Store, tick: u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, store.io, .{ .capacity = 16 });
    defer registry.deinit();
    var chunks_store = try ChunkStore.init(arena.allocator(), store.io, try store.openSpace(chunks.Chunks.id), 1, &registry, try records.Resources.init(arena.allocator(), store.io, .{ .readers = 1, .writers = 1 }));
    var keys: [count][16]u8 = undefined;
    var values: [count][8193]u8 = undefined;
    var requests: [count]records.Get = undefined;
    var lengths: [count]?usize = undefined;
    for (&keys, &values, &requests, 0..) |*key, *value, *request, id| {
        key.* = keyFor(count - 1 - id);
        request.* = .{ .key = key, .destination = value };
    }
    try chunks_store.getBatch(&requests, &lengths);
    var buffer: [8193]u8 = undefined;
    for (values, lengths, 0..) |value, length, id| {
        const expected = valueFor(tick, count - 1 - id, &buffer);
        try std.testing.expectEqual(@as(?usize, if (expected) |bytes| bytes.len else null), length);
        if (expected) |bytes| try std.testing.expectEqualSlices(u8, bytes, value[0..length.?]);
    }
    const before = store.wal_bytes.value();
    try chunks_store.flush();
    try std.testing.expectEqual(before, store.wal_bytes.value());
}

test "spatial records preserve neighbors through growth shrink deletion and eviction" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/tiles", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path };
    for (1..6) |tick| {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        errdefer store.deinit();
        try change(&store, tick);
        try store.waitDurable(store.lastCommit());
        store.deinit();
        store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try verify(&store, tick);
    }
}

fn scenario(store: *storage.Store, acknowledged: *u64) !void {
    try change(store, 2);
    try store.waitDurable(store.lastCommit());
    acknowledged.* = 2;
    try change(store, 3);
}

test "power loss while repacking spatial records recovers an atomic save" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/crash", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try change(&store, 1);
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
            try scenario(&store, &acknowledged);
            events = disk.events;
            store.deinit();
            disk.detach();
        }
        try std.testing.expect(events != 0);
        for (1..events + 1) |cut| for (std.enums.values(fault.Disk.Mode)) |mode| {
            errdefer std.debug.print("chunk power loss short={} cut={d}/{d} mode={t}\n", .{ short, cut, events, mode });
            var store = try storage.Store.init(std.testing.allocator, io, options);
            var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, cut, short);
            defer disk.deinit();
            const modeled = disk.interface();
            store.io = modeled;
            store.filesystem.io = modeled;
            store.maintenance_io.io = modeled;
            var acknowledged: u64 = 1;
            scenario(&store, &acknowledged) catch |err| switch (err) {
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
            try std.testing.expect(recovered.lastTick() >= acknowledged and recovered.lastTick() <= 3);
            try verify(&recovered, recovered.lastTick());
        };
    }
}

test "unrelated tile reads progress during cold reads and mutations" {
    const Actor = struct {
        store: *ChunkStore,
        key: [16]u8,
        bytes: [8193]u8 = undefined,
        gate: ?*fault.Disk.IoGate = null,
        writing: bool = false,
        done: std.Io.Event = .unset,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            if (self.gate) |gate| gate.thread.store(std.Thread.getCurrentId(), .release);
            self.result = self.read();
            self.done.set(std.testing.io);
        }
        fn read(self: *@This()) !void {
            if (self.writing) {
                try self.store.putBatch(&.{.{ .key = &self.key, .value = &.{ 0, 11, 0 } }});
                return;
            }
            var lengths: [1]?usize = undefined;
            try self.store.decodeBatch(&.{.{ .key = &self.key, .destination = &self.bytes }}, &lengths);
            try std.testing.expectEqual(@as(?usize, 3), lengths[0]);
            try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, self.bytes[1..3], .little));
        }
    };
    const io = std.testing.io;
    for ([_]bool{ false, true }) |mutation| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/concurrent-tiles", .{temporary.sub_path});
        const pages = try storage.Resources.init(allocator, io, .{ .cache_pages = 1, .readers = 2, .io_mode = .standard });
        defer pages.deinit();
        var store = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard, .resources = pages, .maximum_wal_pages = 128 });
        defer store.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 64 });
        defer registry.deinit();
        const resources = try records.Resources.init(allocator, io, .{ .readers = 2, .writers = 1 });
        defer resources.deinit();
        const space = try store.openSpace("chunks");
        var initial = try ChunkStore.init(allocator, io, space, 2, &registry, resources);
        var keys = [_][16]u8{ keyFor(0), keyFor(8) };
        const value = [_]u8{ 0, 7, 0 };
        try initial.putBatch(&.{ .{ .key = &keys[0], .value = &value }, .{ .key = &keys[1], .value = &value } });
        try initial.flush();
        var reader = try ChunkStore.init(allocator, io, space, 2, &registry, resources);
        var warm: Actor = .{ .store = &reader, .key = keys[1] };
        if (mutation) try warm.read();
        const root = (try space.getRoot()).?;
        const offset = store.locations.get(@intFromEnum(root)).?.current;
        var disk = try fault.Disk.init(allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
        defer disk.deinit();
        const modeled = disk.interface();
        defer disk.detach();
        store.bindIo(modeled);
        store.resources.cache_index.clearRetainingCapacity();
        var gate: fault.Disk.IoGate = .{ .file = store.wal, .offset = offset + 32 };
        disk.read_gate = &gate;
        var paused: Actor = .{ .store = &reader, .key = keys[0], .gate = &gate, .writing = mutation };
        const first = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Actor.run, .{&paused});
        defer first.join();
        defer gate.release.set(io);
        try gate.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        var independent: Actor = .{ .store = &reader, .key = keys[1] };
        const second = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Actor.run, .{&independent});
        defer second.join();
        defer gate.release.set(io);
        try independent.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try independent.result;
        try std.testing.expect(!paused.done.isSet());
        gate.release.set(io);
        try paused.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try paused.result;
    }
}

test "interleaved duplicate tile writes preserve the final caller value across cache windows" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_]usize{ 1, 2 }) |capacity| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/ordered-{d}", .{ temporary.sub_path, capacity });
        var disk = try storage.Store.init(allocator, std.testing.io, .{ .path = path, .io_mode = .standard });
        defer disk.deinit();
        var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var store = try ChunkStore.init(allocator, std.testing.io, try disk.openSpace("chunks"), capacity, &registry, try records.Resources.init(allocator, std.testing.io, .{ .readers = 1, .writers = 1 }));
        const a = keyFor(0);
        const b = keyFor(4);
        try store.putBatch(&.{
            .{ .key = &a, .value = &.{ 0, 1, 0 } },
            .{ .key = &b, .value = &.{ 0, 2, 0 } },
            .{ .key = &a, .value = &.{ 0, 3, 0 } },
            .{ .key = &b, .value = null },
            .{ .key = &a, .value = &.{ 0, 4, 0 } },
            .{ .key = &b, .value = &.{ 0, 5, 0 } },
        });
        var values: [3][3]u8 = undefined;
        var lengths: [3]?usize = undefined;
        try store.getBatch(&.{
            .{ .key = &b, .destination = &values[0] },
            .{ .key = &a, .destination = &values[1] },
            .{ .key = &a, .destination = &values[2] },
        }, &lengths);
        for (lengths) |length| try std.testing.expectEqual(@as(?usize, 3), length);
        try std.testing.expectEqualSlices(u8, &.{ 0, 5, 0 }, &values[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 4, 0 }, &values[1]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 4, 0 }, &values[2]);
    }
}
