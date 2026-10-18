const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const chunks = @import("chunks");
const inventories = @import("inventories");
const metrics = @import("metrics");
const fault = @import("fault_disk");
const testing = @import("storage_testing");
const test_options = @import("options");
const builtin = @import("builtin");

const section_count = 16;
const slot_count = 64;
const Slot = struct { tag: u32 = 0, count: u16 = 0, revision: u64 = 0 };
const Model = struct { blocks: [section_count][4096]u16 = @splat(@splat(0)), slots: [slot_count]Slot = @splat(.{}) };

const Plugins = struct {
    world: *chunks.Chunks,
    inventory: *inventories.Inventories,

    fn init(allocator: std.mem.Allocator, store: *storage.Store, registry: *metrics.Registry) !Plugins {
        return .{
            .world = try chunks.Chunks.init(allocator, store.io, .{ .cache_sections = 2, .cache_tiles = 1 }, .{ .metrics = registry, .storage = try store.openSpace(chunks.Chunks.id) }),
            .inventory = try inventories.Inventories.init(allocator, store.io, .{ .cache_slots = 2, .cache_items = 2 }, .{ .metrics = registry, .storage = try store.openSpace(inventories.Inventories.id) }),
        };
    }

    fn checkpoint(self: Plugins, store: *storage.Store) !void {
        try self.world.checkpoint(try store.openSpace(chunks.Chunks.id));
        try self.inventory.checkpoint(try store.openSpace(inventories.Inventories.id));
    }

    fn verify(self: Plugins, model: *const Model) !void {
        for (model.blocks, 0..) |expected, id| {
            const lease = try self.world.acquire(section(id));
            defer lease.release();
            for (expected, 0..) |state, index| try std.testing.expectEqual(state, lease.get(@intCast(index)));
        }
        var buffer: [65536]u8 = undefined;
        for (model.slots, 0..) |expected, id| {
            const actual = try self.inventory.get(slot(id));
            try std.testing.expectEqual(expected.revision, actual.revision);
            try std.testing.expectEqual(expected.tag != 0, actual.stack != null);
            if (expected.tag == 0) continue;
            const bytes = definition(expected.tag, &buffer);
            var key: inventories.ItemId = undefined;
            std.crypto.hash.Blake3.hash(bytes, &key, .{});
            try std.testing.expectEqual(expected.count, actual.stack.?.count);
            try std.testing.expectEqualSlices(u8, &key, &actual.stack.?.item);
            const item = try self.inventory.acquireItem(key);
            defer item.release();
            try std.testing.expectEqualSlices(u8, bytes, item.read().?);
        }
    }
};

fn section(id: usize) chunks.Section {
    return .{ .world = @intCast(id / 8), .x = @as(i32, @intCast(id % 8 / 2)) - 2, .z = @as(i32, @intCast(id % 2)) - 1, .y = -4 };
}

fn slot(id: usize) inventories.Slot {
    return .{ .owner = 100 + id / 16, .index = @intCast(if (id / 16 % 2 == 0) id % 16 else if (id % 16 == 15) 65535 else id % 16 * 4096) };
}

fn definition(tag: u32, output: []u8) []const u8 {
    const lengths = [_]usize{ 3, 519, 4064, 4065, 65536 };
    const length = lengths[tag % lengths.len];
    var random = std.Random.DefaultPrng.init(tag);
    random.random().bytes(output[0..length]);
    return output[0..length];
}

fn mutate(plugins: Plugins, model: *Model, random: std.Random, step: usize) !void {
    const id = random.uintLessThan(usize, section_count);
    var edits: [4096]chunks.BlockEdit = undefined;
    const count: usize = if (step % 7 == 0) edits.len else 16;
    for (edits[0..count], 0..) |*edit, at| {
        const index: u12 = if (count == edits.len) @intCast(at) else random.int(u12);
        const state: u16 = if (step % 21 == 0) 0 else if (count == edits.len) @intCast(at % (1 + step % 1500)) else random.uintLessThan(u16, 5000);
        edit.* = .{ .index = index, .state = state };
        model.blocks[id][index] = state;
    }
    try plugins.world.setBlocks(section(id), edits[0..count]);
    const target = random.uintLessThan(usize, slot_count);
    const previous = model.slots[target];
    const tag: u32 = if (step % 4 == 0) 0 else random.uintLessThan(u32, 256) + 1;
    const count_items: u16 = if (tag == 0) 0 else 1 + random.uintLessThan(u16, 64);
    var bytes: [65536]u8 = undefined;
    const item = if (tag == 0) null else try plugins.inventory.defineItem(definition(tag, &bytes));
    try std.testing.expect(try plugins.inventory.set(slot(target), previous.revision, if (item) |key| .{ .item = key, .count = count_items } else null));
    model.slots[target] = .{ .tag = tag, .count = count_items, .revision = previous.revision + 1 };
    if (step % 3 == 0) {
        const from = random.uintLessThan(usize, slot_count);
        const to = (from + 1 + random.uintLessThan(usize, slot_count - 1)) % slot_count;
        const source = model.slots[from];
        const destination = model.slots[to];
        const stale = step % 29 == 0;
        const expected: inventories.MoveResult = if (stale) .stale else if (source.tag == 0) .empty else if (destination.tag != 0 and destination.tag != source.tag) .incompatible else if (destination.count == 64) .full else .moved;
        try std.testing.expectEqual(expected, try plugins.inventory.move(.{ .from = slot(from), .to = slot(to), .count = 1, .maximum_stack = 64, .from_revision = source.revision + @intFromBool(stale), .to_revision = destination.revision }));
        if (expected == .moved) {
            model.slots[from] = .{ .tag = if (source.count == 1) 0 else source.tag, .count = source.count - 1, .revision = source.revision + 1 };
            model.slots[to] = .{ .tag = source.tag, .count = destination.count + 1, .revision = destination.revision + 1 };
        }
    }
}

test "mixed plugin saves preserve the model through eviction maintenance and interrupted ticks" {
    const io = std.testing.io;
    const configurations = [_]storage.Store.Options{ .{ .path = "", .submission = .standard }, .{ .path = "", .submission = .uring } };
    for (configurations[0..if (builtin.os.tag == .linux) 2 else 1]) |configured| {
        var directory = try testing.directory(.{});
        defer directory.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/mixed", .{directory.sub_path});
        defer std.testing.allocator.free(path);
        var options = configured;
        options.path = path;
        options.maximum_wal_pages = 4096;
        options.maximum_pages = 4096;
        options.checkpoint_bytes = 64 * 1024;
        var model: Model = .{};
        var saved = model;
        var tick: u64 = 0;
        var random = std.Random.DefaultPrng.init(0x4d49584544534156);
        for (0..test_options.rounds) |round| {
            var store = try storage.Store.init(std.testing.allocator, io, options);
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
            defer registry.deinit();
            const plugins = try Plugins.init(arena.allocator(), &store, &registry);
            try std.testing.expectEqual(tick, store.lastTick());
            try plugins.verify(&saved);
            model = saved;
            for (0..8) |step| {
                errdefer std.debug.print("mixed storage backend={t} round={d} step={d} phase={t}\n", .{ options.submission, round, step, store.phase });
                try mutate(plugins, &model, random.random(), round * 8 + step);
                if (step == 3 or (step == 7 and round % 4 != 0)) {
                    try plugins.checkpoint(&store);
                    tick += 1;
                    try store.submitSync(try store.commit(tick));
                    saved = model;
                }
                for (0..16) |_| _ = try store.maintain(32);
            }
            try plugins.verify(&model);
            try store.waitDurable(store.lastCommit());
        }
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        const plugins = try Plugins.init(arena.allocator(), &store, &registry);
        try std.testing.expectEqual(tick, store.lastTick());
        try plugins.verify(&saved);
    }
}

fn change(store: *storage.Store, tick: u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, store.io, .{ .enabled = false });
    defer registry.deinit();
    const plugins = try Plugins.init(arena.allocator(), store, &registry);
    var edits: [4096]chunks.BlockEdit = undefined;
    for (&edits, 0..) |*edit, index| edit.* = .{ .index = @intCast(index), .state = @intCast(index % (tick * 7)) };
    try plugins.world.setBlocks(section(0), &edits);
    try plugins.world.setBlocks(section(9), &edits);
    var buffer: [65536]u8 = undefined;
    const item = try plugins.inventory.defineItem(definition(@intCast(tick + 2), &buffer));
    for ([_]usize{ 0, 31 }) |id| {
        const previous = try plugins.inventory.get(slot(id));
        try std.testing.expect(try plugins.inventory.set(slot(id), previous.revision, .{ .item = item, .count = @intCast(tick) }));
    }
    try plugins.checkpoint(store);
    var value: [8]u8 = undefined;
    std.mem.writeInt(u64, &value, tick, .little);
    try records.Value.init(try store.openSpace("metadata")).write(&value);
    _ = try store.commit(tick);
}

fn scenario(store: *storage.Store, acknowledged: *u64) !void {
    try change(store, 2);
    try store.waitDurable(store.lastCommit());
    acknowledged.* = 2;
    try change(store, 3);
}

fn recovered(store: *storage.Store) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, store.io, .{ .enabled = false });
    defer registry.deinit();
    const plugins = try Plugins.init(arena.allocator(), store, &registry);
    const tick = store.lastTick();
    for ([_]usize{ 0, 9 }) |id| {
        const lease = try plugins.world.acquire(section(id));
        defer lease.release();
        for (0..4096) |index| try std.testing.expectEqual(@as(u16, @intCast(index % (tick * 7))), lease.get(@intCast(index)));
    }
    var buffer: [65536]u8 = undefined;
    const bytes = definition(@intCast(tick + 2), &buffer);
    var key: inventories.ItemId = undefined;
    std.crypto.hash.Blake3.hash(bytes, &key, .{});
    for ([_]usize{ 0, 31 }) |id| {
        const value = try plugins.inventory.get(slot(id));
        try std.testing.expectEqual(@as(u16, @intCast(tick)), value.stack.?.count);
        try std.testing.expectEqualSlices(u8, &key, &value.stack.?.item);
    }
    const item = try plugins.inventory.acquireItem(key);
    defer item.release();
    try std.testing.expectEqualSlices(u8, bytes, item.read().?);
    var value: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 8), try records.Value.init(try store.openSpace("metadata")).read(&value));
    try std.testing.expectEqual(tick, std.mem.readInt(u64, &value, .little));
}

test "power loss cannot mix chunk inventory item and metadata versions" {
    const io = std.testing.io;
    var directory = try testing.directory(.{});
    defer directory.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/atomic", .{directory.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 };
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
            store.checkpoint_io.io = modeled;
            var acknowledged: u64 = 1;
            try scenario(&store, &acknowledged);
            events = disk.events;
            store.deinit();
            disk.detach();
        }
        for (1..events + 1) |cut| for (std.enums.values(fault.Disk.Mode)) |mode| {
            errdefer std.debug.print("mixed power loss short={} cut={d}/{d} mode={t}\n", .{ short, cut, events, mode });
            var store = try storage.Store.init(std.testing.allocator, io, options);
            var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, cut, short);
            defer disk.deinit();
            const modeled = disk.interface();
            store.io = modeled;
            store.filesystem.io = modeled;
            store.checkpoint_io.io = modeled;
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
            var restored = try storage.Store.init(std.testing.allocator, disk.interface(), options);
            defer {
                restored.deinit();
                disk.detach();
            }
            try std.testing.expect(restored.lastTick() >= acknowledged and restored.lastTick() <= 3);
            try recovered(&restored);
        };
        try std.testing.expect(events != 0);
    }
}
