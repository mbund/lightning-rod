const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const sessions = @import("sessions");
const catalog = @import("catalog.zig");
const islands = @import("island.zig");
const Channel = @import("global_chat.zig").Channel;
const Worlds = @import("worlds.zig").Worlds;
const records = @import("records");
const Slots = @import("slots.zig").Slots;
const vanilla = @import("vanilla");
const game_data = @import("game_data");
const chunks = @import("chunks");

const PauseCounts = struct { requested: usize, waits: usize };

fn pauseCounts(count: usize) !PauseCounts {
    const Probe = struct {
        threaded: std.Io.Threaded,
        vtable: std.Io.VTable,
        workers: []islands.Pool.Worker,
        waits: usize = 0,
        requested_at_first_wait: usize = 0,

        fn wait(raw: ?*anyopaque, address: *const u32, _: u32) void {
            const threaded: *std.Io.Threaded = @ptrCast(@alignCast(raw.?));
            const self: *@This() = @fieldParentPtr("threaded", threaded);
            for (self.workers) |*worker| {
                if (@intFromPtr(address) == @intFromPtr(&worker.background_parked)) {
                    if (self.waits == 0) for (self.workers) |*other| {
                        self.requested_at_first_wait += @intFromBool(other.background_mode.load(.acquire) == .paused);
                    };
                    self.waits += 1;
                    @atomicStore(std.Io.Event, &worker.background_parked, .is_set, .release);
                    return;
                }
                if (@intFromPtr(address) == @intFromPtr(&worker.done)) {
                    std.debug.assert(worker.requested.swap(false, .acquire));
                    @atomicStore(std.Io.Event, &worker.done, .is_set, .release);
                    return;
                }
            }
            unreachable;
        }
    };
    const workers = try std.testing.allocator.alloc(islands.Pool.Worker, count);
    defer std.testing.allocator.free(workers);
    var probe: Probe = .{
        .threaded = .init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing }),
        .vtable = undefined,
        .workers = workers,
    };
    defer probe.threaded.deinit();
    probe.vtable = probe.threaded.io().vtable.*;
    probe.vtable.futexWaitUncancelable = Probe.wait;
    const io: std.Io = .{ .userdata = &probe.threaded, .vtable = &probe.vtable };
    for (workers, 0..) |*worker, index| {
        worker.* = .{ .io = io, .record_resources = undefined, .index = index };
        worker.background_mode.store(.active, .release);
    }
    var pool: islands.Pool = .{ .workers = workers, .slots = undefined, .limit = 1 };
    try pool.apply(&.{}, .pause);
    try std.testing.expectEqual(count, probe.requested_at_first_wait);
    for (workers) |*worker| {
        try std.testing.expect(worker.background_mode.load(.acquire) == .paused);
        try std.testing.expect(worker.background_parked.isSet() and worker.done.isSet());
    }
    return .{ .requested = probe.requested_at_first_wait, .waits = probe.waits };
}

pub fn benchmarkPause() !void {
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try output.interface.writeAll("workers | pause requests before first wait | pause waits\n");
    for ([_]usize{ 1, 2, 4 }) |count| {
        const measured = try pauseCounts(count);
        try output.interface.print("{d:7} | {d:32} | {d}\n", .{ count, measured.requested, measured.waits });
    }
    try output.interface.flush();
}

test "all background workers receive their pause before waiting for any acknowledgment" {
    for ([_]usize{ 1, 2, 4 }) |count| {
        const measured = try pauseCounts(count);
        try std.testing.expectEqual(count, measured.requested);
    }
}

test "bounded worker batches reuse scratch and retire worlds before admitting destinations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var memory = lightning_rod.Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const allocator = memory.allocator("test");
    const content = try vanilla.prepareDefinitions(memory.allocator("definitions"));
    var selected = try protocols.Default.init(allocator);
    defer selected.deinit(allocator);
    var endpoints: [3]*sessions.Service = undefined;
    var initialized: usize = 0;
    defer for (endpoints[0..initialized]) |endpoint| {
        for (endpoint.occupied) |*occupied| occupied.store(false, .release);
        endpoint.deinit();
    };
    for (&endpoints, 0..) |*endpoint, index| {
        endpoint.* = try sessions.Service.init(allocator, std.testing.io, undefined, .{
            .connections = if (index == 0) catalog.maximum_players else catalog.island_connections,
            .pages = 1,
            .page_bytes = 128 * 1024,
            .protocols = &selected.values,
        });
        initialized += 1;
    }
    var routing: sessions.Routing = .{ .endpoints = &endpoints };
    var directory: catalog.Catalog = .{ .io = std.testing.io };
    var chat: Channel = .{ .io = std.testing.io };
    try directory.load(1, .{ .members = .{ catalog.Member.named(1, "alice"), .{ .uuid = 0 }, .{ .uuid = 0 }, .{ .uuid = 0 } }, .count = 1 });
    const workers = try allocator.alloc(islands.Pool.Worker, 1);
    defer allocator.free(workers);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer allocator.free(path);
    var store = try lightning_rod.storage.Store.init(allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var world_storage = try Worlds.init(&store, std.testing.io);
    const resources = try records.Resources.init(allocator, std.testing.io, .{ .readers = 2, .writers = 2 });
    defer resources.deinit();
    workers[0] = .{ .io = std.testing.io, .record_resources = resources, .index = 0 };
    var slots = try Slots.init(allocator, 2);
    defer slots.deinit();
    var pool: islands.Pool = .{ .workers = workers, .slots = &slots, .limit = 2 };
    var worlds: [3]islands.Island = undefined;
    for (&worlds, 0..) |*world, index| {
        world.* = .{
            .id = index,
            .worlds = &world_storage,
            .record_resources = resources,
            .io = workers[0].io,
            .wakeup = &workers[0].ready,
            .routing = &routing,
            .catalog = &directory,
            .content = content,
            .chat = &chat,
            .index = index,
            .worker = 0,
            .expected_tick = null,
        };
    }
    for (&worlds) |*world| try world.load();
    for (worlds) |world| try std.testing.expect(world.scope == null and world.simulation == null);
    try pool.reserve(&worlds);
    try pool.start(&worlds);
    defer pool.stop();
    defer pool.apply(&worlds, .close) catch unreachable;
    for (worlds) |world| try std.testing.expect(world.scope == null and world.simulation == null);
    for (world_storage.roots) |root| try std.testing.expectEqual(@as(u64, 0), root);
    const reserved = memory.assigned_bytes;
    memory.seal();
    for (endpoints) |endpoint| endpoint.occupied[0].store(true, .release);
    try pool.reconcile(&worlds);
    try std.testing.expect(worlds[0].simulation != null and worlds[1].simulation != null);
    try std.testing.expect(worlds[2].simulation == null);
    try std.testing.expect(worlds[0].slot == &slots.hub);
    const block_index: u12 = 12;
    const section: vanilla.Section = .{ .world = worlds[0].simulation.?.get(vanilla.VanillaWorlds).overworld, .x = 0, .y = 4, .z = 0 };
    try worlds[0].simulation.?.get(vanilla.Chunks).setBlocks(section, &.{.{ .index = block_index, .state = game_data.registry.block_dirt_default_state }});
    for (worlds[0..2]) |world| try std.testing.expectEqual(@intFromPtr(&workers[0].scratch), @intFromPtr(world.simulation.?.temporary.buffer.ptr));
    try pool.apply(&worlds, .tick);
    try std.testing.expectEqual(@as(u64, 1), worlds[0].simulation.?.completed_tick);
    try std.testing.expectEqual(@as(u64, 1), worlds[1].simulation.?.completed_tick);
    const Gate = struct {
        source: chunks.Source,
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        fn generate(self: *@This(), io: std.Io, batch: chunks.Source.Batch) void {
            self.entered.set(io);
            self.release.waitUncancelable(io);
            self.source.readMany(io, batch);
        }
    };
    const Tick = struct {
        pool: *islands.Pool,
        worlds: []islands.Island,
        done: std.Io.Event = .unset,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = self.pool.apply(self.worlds, .tick);
            self.done.set(std.testing.io);
        }
    };
    try pool.apply(&worlds, .pause);
    const terrain = worlds[0].simulation.?.get(vanilla.Chunks);
    var gate: Gate = .{ .source = terrain.generation.source.? };
    terrain.generation.source = chunks.Source.init(&gate, Gate.generate);
    var ready: [1]bool = undefined;
    var prepared: [1]chunks.Lease = undefined;
    try terrain.prepareMany(&.{.{ .sections = &.{.{ .world = section.world, .x = 8, .y = 4, .z = 0 }}, .leases = &prepared, .priority = .{} }}, &ready);
    if (ready[0]) terrain.releaseMany(&prepared);
    try std.testing.expect(!ready[0]);
    try pool.apply(&worlds, .resume_io);
    defer gate.release.set(std.testing.io);
    try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    var tick: Tick = .{ .pool = &pool, .worlds = &worlds };
    const advancing = try std.Thread.spawn(.{}, Tick.run, .{&tick});
    defer advancing.join();
    defer gate.release.set(std.testing.io);
    try tick.done.waitTimeout(std.testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try tick.result;
    try std.testing.expect(!gate.release.isSet());
    gate.release.set(std.testing.io);
    try pool.apply(&worlds, .pause);
    terrain.generation.source = gate.source;
    try pool.apply(&worlds, .resume_io);
    endpoints[0].occupied[0].store(false, .release);
    try pool.reconcile(&worlds);
    try std.testing.expect(worlds[0].simulation == null);
    try std.testing.expect(!slots.hub.occupied);
    try std.testing.expectEqual(@as(u64, 2), worlds[0].last_tick);
    try std.testing.expect(worlds[2].simulation != null);
    try std.testing.expectEqual(@intFromPtr(&workers[0].scratch), @intFromPtr(worlds[2].simulation.?.temporary.buffer.ptr));
    endpoints[2].occupied[0].store(false, .release);
    endpoints[0].occupied[0].store(true, .release);
    try pool.reconcile(&worlds);
    try std.testing.expect(worlds[2].simulation == null);
    try std.testing.expect(worlds[0].slot == &slots.hub);
    try std.testing.expectEqual(@as(u64, 2), worlds[0].simulation.?.completed_tick);
    try pool.apply(&worlds, .pause);
    try pool.apply(&worlds, .save);
    try pool.apply(&worlds, .close);
    try store.waitDurable(try store.commit(1));
    worlds[0].slot = &slots.hub;
    slots.hub.occupied = true;
    worlds[0].scheduled = true;
    try worlds[0].execute(.open, &workers[0].scratch);
    defer worlds[0].execute(.close, &workers[0].scratch) catch unreachable;
    {
        const Read = struct {
            fn run(chunk_cache: *vanilla.Chunks, at: vanilla.Section, index: u12) !u16 {
                const chunk = try chunk_cache.acquire(at);
                defer chunk.release();
                return chunk.view().get(index);
            }
        };
        try std.testing.expectEqual(@as(u16, game_data.registry.block_dirt_default_state), try Read.run(worlds[0].simulation.?.get(vanilla.Chunks), section, block_index));
    }
    var restored = (try world_storage.open(1)).?;
    try std.testing.expectEqual(@as(u128, 1), (try catalog.State.read(try restored.transaction().openSpace(catalog.island_namespace))).owner().?);
    try std.testing.expectEqual(@as(u64, 2), restored.tick);
    try std.testing.expectEqual(reserved, memory.assigned_bytes);
}
