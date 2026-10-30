const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const reload = @import("reload");
const catalog = @import("catalog.zig");
const IslandCommands = @import("commands.zig").IslandCommands;
const Terrain = @import("terrain.zig").Terrain;
const global_chat = @import("global_chat.zig");
const Worlds = @import("worlds.zig").Worlds;
const records = @import("records");
const Slots = @import("slots.zig").Slots;

const operators = blk: {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:CMakeLists_txt", &digest, .{});
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    break :blk [_]u128{std.mem.readInt(u128, &digest, .big)};
};

const defaults = lightning_rod.plugin.remove(lightning_rod.plugin.replace(lightning_rod.plugin.remove(lightning_rod.plugin.remove(vanilla.plugins(), vanilla.ChatInput), vanilla.JoinLeaveMessages), .{lightning_rod.plugin.configured(Terrain, .{ .kind = .island })}), vanilla.Vanilla);
const Selections = lightning_rod.plugin.Compose(std.meta.Tuple(&.{ @TypeOf(defaults), lightning_rod.plugin.Selection(IslandCommands), lightning_rod.plugin.Selection(global_chat.GlobalChat) }));
const Simulation = lightning_rod.Simulation(Selections);

fn selections(content: vanilla.definition_provider.Dependencies, config: IslandCommands.Configuration, chat: *global_chat.Channel, resources: *records.Resources, wakeup: *std.Io.Event, request: *reload.Request) !Selections {
    const column_sections = (try content.dimensions.dimension("minecraft:overworld")).section_count;
    return lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(lightning_rod.plugin.replace(defaults, vanilla.definition_provider.selections(content)), .{
            lightning_rod.plugin.configured(records.Workspaces, .{ .shared = resources }),
            lightning_rod.plugin.configured(vanilla.Operators, .{ .operators = &operators }),
            lightning_rod.plugin.configured(sessions.World, .{ .endpoint = config.routing.endpoints[config.index] }),
            lightning_rod.plugin.configured(Terrain, .{ .kind = if (config.index == 0) .hub else .island }),
            lightning_rod.plugin.configured(vanilla.Reload, .{ .request = request }),
            lightning_rod.plugin.configured(vanilla.Chunks, .{ .wakeup = wakeup, .cache_sections = column_sections * 2, .demand_sections = column_sections, .cache_tiles = 4 }),
            lightning_rod.plugin.configured(vanilla.Inventories, .{ .cache_items = 4 }),
            lightning_rod.plugin.configured(vanilla.BlockSynchronization, .{ .delta_sections = 32, .queued_sections = 32 }),
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = if (config.index == 0) catalog.maximum_players else catalog.island_connections, .render_distance = 4, .world_border = 512 }),
        }),
        lightning_rod.plugin.configured(IslandCommands, config),
        lightning_rod.plugin.configured(global_chat.GlobalChat, .{ .channel = chat }),
    });
}
pub const Operation = enum { open, retire, tick, pause, save, resume_io, close };

pub const Island = struct {
    id: u128,
    slot: ?*Slots.Slot = null,
    worlds: *Worlds,
    record_resources: *records.Resources,
    io: std.Io,
    wakeup: *std.Io.Event,
    terrain: ?vanilla.Terrain = null,
    terrain_active: bool = false,
    routing: *sessions.Routing,
    catalog: *catalog.Catalog,
    chat: *global_chat.Channel,
    content: vanilla.definition_provider.Dependencies,
    index: usize,
    worker: usize,
    expected_tick: ?u64,
    last_tick: u64 = 0,
    scheduled: bool = false,
    request: reload.Request = .{ .enabled = true },
    scope: ?lightning_rod.storage.Scope = null,
    simulation: ?*Simulation = null,

    pub fn load(self: *Island) !void {
        self.scope = try self.worlds.open(self.index);
        if (self.scope == null) {
            if (self.expected_tick) |expected| if (expected != 0) return error.ResumeCheckpointMismatch;
            return;
        }
        self.last_tick = self.scope.?.tick;
        if (self.expected_tick) |expected| if (self.last_tick != expected) return error.ResumeCheckpointMismatch;
        try self.catalog.load(self.index, try catalog.State.read(try self.scope.?.transaction().openSpace(catalog.island_namespace)));
    }

    pub fn execute(self: *Island, operation: Operation, scratch: []u8) anyerror!void {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .clock = .awake, .raw = .fromSeconds(30) });
        switch (operation) {
            .open => {
                if (!self.scheduled) return;
                std.debug.assert(self.simulation == null);
                self.scheduled = false;
                const allocator = self.slot.?.allocator();
                if (self.scope == null) self.scope = try self.worlds.create(self.index);
                const plugins = try selections(self.content, .{ .catalog = self.catalog, .routing = self.routing, .index = self.index }, self.chat, self.record_resources, self.wakeup, &self.request);
                self.simulation = try Simulation.init(allocator, self.io, self.worlds.space.store, .{
                    .scratch = scratch,
                    .scope = &self.scope.?,
                });
                const simulation = self.simulation.?;
                try simulation.initialize(plugins, .{
                    .metrics = &simulation.metrics,
                    .routing = self.routing,
                });
                const definitions = vanilla.definition_provider.from(@TypeOf(simulation.*), simulation);
                inline for (@typeInfo(vanilla.definition_provider.Dependencies).@"struct".fields) |field| try @field(definitions, field.name).registry.validate();
                self.terrain = .{ .chunks = simulation.get(vanilla.Chunks), .streaming = simulation.get(vanilla.Streaming), .blocks = simulation.get(vanilla.BlockSynchronization), .io = self.io };
            },
            .retire => {
                const simulation = self.simulation orelse return;
                if (self.routing.endpoints[self.index].hasConnections()) return;
                for (simulation.get(vanilla.Players).records) |player| if (player.handle != null) return;
                if (self.terrain_active) self.terrain.?.stop();
                self.terrain_active = false;
                try simulation.unload(deadline);
                self.last_tick = self.scope.?.tick;
                simulation.deinit(self.slot.?.allocator());
                self.simulation = null;
                self.slot.?.release();
                self.slot = null;
            },
            .tick => if (self.simulation) |simulation| try simulation.tick(),
            .pause => if (self.terrain_active) {
                self.terrain.?.stop();
                self.terrain_active = false;
            },
            .save => {
                if (self.simulation) |simulation| try simulation.stageCheckpoint();
            },
            .resume_io => {},
            .close => {
                if (self.simulation) |simulation| {
                    if (self.terrain_active) self.terrain.?.stop();
                    self.terrain_active = false;
                    if (simulation.state != .closed) try simulation.unload(deadline);
                    self.last_tick = self.scope.?.tick;
                    simulation.deinit(self.slot.?.allocator());
                    self.simulation = null;
                }
                if (self.slot) |slot| slot.release();
                self.slot = null;
            },
        }
    }
};

pub const maximum = catalog.endpoints;

pub const Pool = struct {
    pub const Worker = struct {
        io: std.Io,
        record_resources: *records.Resources,
        index: usize,
        scratch: [256 * 1024]u8 = undefined,
        thread: ?std.Thread = null,
        background_thread: ?std.Thread = null,
        background_ready: std.Io.Event = .unset,
        background_parked: std.Io.Event = .unset,
        background_mode: std.atomic.Value(enum(u8) { active, paused, stopped }) = .init(.paused),
        ready: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        requested: std.atomic.Value(bool) = .init(false),
        stopping: std.atomic.Value(bool) = .init(false),
        operation: Operation = .tick,
        islands: []Island = &.{},
        active: [catalog.maximum_active]?*Island = @splat(null),
        failure: ?anyerror = null,
        background_failure: ?anyerror = null,
        background_failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *Worker) void {
            defer self.done.set(self.io);
            while (!self.stopping.load(.acquire)) {
                self.ready.waitUncancelable(self.io);
                self.ready.reset();
                if (self.stopping.load(.acquire)) return;
                if (self.requested.swap(false, .acquire)) {
                    self.execute(self.operation) catch |err| {
                        self.failure = err;
                    };
                    self.done.set(self.io);
                }
            }
        }

        fn runBackground(self: *Worker) void {
            defer self.background_parked.set(self.io);
            while (self.background_mode.load(.acquire) != .stopped) {
                if (self.background_mode.load(.acquire) == .paused) {
                    for (self.active) |maybe_island| {
                        const island = maybe_island orelse continue;
                        if (island.terrain_active) island.terrain.?.stop();
                        island.terrain_active = false;
                    }
                    self.background_parked.set(self.io);
                    self.background_ready.waitUncancelable(self.io);
                    self.background_ready.reset();
                    continue;
                }
                if (!self.background_failed.load(.acquire)) for (self.active) |maybe_island| {
                    const island = maybe_island orelse continue;
                    if (!island.terrain_active) {
                        island.terrain.?.start();
                        island.terrain_active = true;
                    }
                    island.terrain.?.poll() catch |err| {
                        self.background_failure = err;
                        self.background_failed.store(true, .release);
                        break;
                    };
                };
                self.background_ready.waitUncancelable(self.io);
                self.background_ready.reset();
            }
            for (self.active) |maybe_island| {
                const island = maybe_island orelse continue;
                if (island.terrain_active) island.terrain.?.stop();
                island.terrain_active = false;
            }
        }

        fn requestBackgroundPause(self: *Worker) void {
            self.background_mode.store(.paused, .release);
            self.background_ready.set(self.io);
        }

        fn resumeBackground(self: *Worker) void {
            self.background_parked.reset();
            self.background_mode.store(.active, .release);
            self.background_ready.set(self.io);
        }

        fn execute(self: *Worker, operation: Operation) !void {
            for (self.islands) |*island| {
                if (island.worker != self.index) continue;
                island.io = self.io;
                island.wakeup = &self.background_ready;
                island.record_resources = self.record_resources;
                try island.execute(operation, &self.scratch);
            }
            if (operation != .open and operation != .retire and operation != .close) return;
            std.debug.assert(self.background_parked.isSet());
            @memset(&self.active, null);
            var count: usize = 0;
            for (self.islands) |*island| {
                if (island.worker != self.index or island.simulation == null) continue;
                self.active[count] = island;
                count += 1;
            }
        }
    };

    workers: []Worker,
    slots: *Slots,
    limit: usize = catalog.maximum_active,
    paused: bool = false,
    applying: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Pool, islands: []Island) !void {
        errdefer self.stop();
        for (self.workers) |*worker| {
            worker.islands = islands;
            worker.background_thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Worker.runBackground, .{worker});
            worker.background_parked.waitUncancelable(worker.io);
            worker.thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Worker.run, .{worker});
        }
    }

    pub fn stop(self: *Pool) void {
        for (self.workers) |*worker| {
            worker.stopping.store(true, .release);
            worker.ready.set(worker.io);
        }
        for (self.workers) |*worker| {
            if (worker.thread) |thread| thread.join();
            worker.thread = null;
        }
        for (self.workers) |*worker| if (worker.background_thread != null) {
            worker.background_mode.store(.stopped, .release);
            worker.background_ready.set(worker.io);
        };
        for (self.workers) |*worker| {
            if (worker.background_thread) |thread| thread.join();
            worker.background_thread = null;
        }
    }

    pub fn reserve(self: *Pool, islands: []Island) !void {
        std.debug.assert(islands.len >= 2 and self.limit <= self.slots.islands.len);
        const Reserve = struct {
            fn run(worker: *Worker, prototype: *const Island, slot: *Slots.Slot) !void {
                slot.occupied = true;
                defer slot.release();
                const allocator = slot.allocator();
                var request: reload.Request = .{ .enabled = true };
                const simulation = try Simulation.init(allocator, worker.io, prototype.worlds.space.store, .{ .scratch = &worker.scratch });
                try simulation.reserve(try selections(prototype.content, .{ .catalog = prototype.catalog, .routing = prototype.routing, .index = prototype.index }, prototype.chat, worker.record_resources, &worker.background_ready, &request), .{ .metrics = &simulation.metrics, .routing = prototype.routing });
                try simulation.unload(std.Io.Clock.Timestamp.fromNow(worker.io, .{ .clock = .awake, .raw = .fromSeconds(30) }));
                simulation.deinit(allocator);
            }
        };
        try Reserve.run(&self.workers[0], &islands[0], &self.slots.hub);
        self.slots.hub.seal();
        std.log.info("event=world_memory_reserved kind=hub instances=1 bytes={d}", .{self.slots.hub.reserved_bytes});
        var reserved: usize = 0;
        for (self.slots.islands, 0..) |*slot, index| {
            try Reserve.run(&self.workers[index % self.workers.len], &islands[1], slot);
            slot.seal();
            reserved += slot.reserved_bytes;
        }
        std.log.info("event=world_memory_reserved kind=island instances={d} bytes={d}", .{ self.slots.islands.len, reserved });
    }

    pub fn apply(self: *Pool, _: []Island, operation: Operation) !void {
        const busy = self.applying.swap(true, .acq_rel);
        std.debug.assert(!busy);
        defer self.applying.store(false, .release);
        if (operation != .close and operation != .pause) for (self.workers) |*worker| {
            if (worker.background_failed.load(.acquire)) return worker.background_failure.?;
        };
        const lifecycle = operation == .open or operation == .retire or operation == .close or operation == .pause;
        if (lifecycle) {
            for (self.workers) |*worker| worker.requestBackgroundPause();
            for (self.workers) |*worker| worker.background_parked.waitUncancelable(worker.io);
        }
        if (operation == .pause) self.paused = true;
        if (operation == .resume_io) self.paused = false;
        for (self.workers) |*worker| {
            worker.done.reset();
            worker.failure = null;
            worker.operation = operation;
            worker.requested.store(true, .release);
            worker.ready.set(worker.io);
        }
        var failure: ?anyerror = null;
        for (self.workers) |*worker| {
            worker.done.waitUncancelable(worker.io);
            if (worker.background_failed.load(.acquire) and failure == null) failure = worker.background_failure.?;
            if (worker.failure) |err| if (failure == null) {
                failure = err;
            };
        }
        if (failure) |err| return err;
        if (!self.paused and operation != .close and (lifecycle or operation == .resume_io))
            for (self.workers) |*worker| worker.resumeBackground();
    }

    pub fn reconcile(self: *Pool, islands: []Island) !void {
        const retiring = for (islands) |*island| {
            if (island.simulation == null or island.routing.endpoints[island.index].hasConnections()) continue;
            const occupied = for (island.simulation.?.get(vanilla.Players).records) |player| {
                if (player.handle != null) break true;
            } else false;
            if (!occupied) break true;
        } else false;
        if (retiring) try self.apply(islands, .retire);
        var count: usize = 0;
        var loads: [4]usize = @splat(0);
        var opening = false;
        for (islands) |*island| if (island.simulation != null) {
            count += 1;
            loads[island.worker] += 1;
        };
        std.debug.assert(count <= self.limit);
        for (islands) |*island| {
            if (count == self.limit) break;
            if (island.simulation != null or !island.routing.endpoints[island.index].hasConnections()) continue;
            island.slot = try self.slots.acquire(island.index == 0);
            island.scheduled = true;
            opening = true;
            const worker = std.mem.indexOfMin(usize, loads[0..self.workers.len]);
            island.worker = worker;
            loads[worker] += 1;
            count += 1;
        }
        if (opening) try self.apply(islands, .open);
    }
};
