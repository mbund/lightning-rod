const std = @import("std");
const plugin = @import("plugin.zig");
const runtime = @import("plugin_runtime.zig");
const PluginAllocator = @import("plugin_allocator.zig").PluginAllocator;
const metrics = @import("metrics");
const lifecycle = @import("plugin_lifecycle.zig");
const storage = @import("storage");
const Checkpoint = @import("checkpoint.zig").Checkpoint;

const assert = std.debug.assert;

/// Dirty cache evictions may write between checkpoints.
pub const Autosave = struct {
    ticks: ?u32 = 1200,
};

pub const Configuration = struct {
    autosave: Autosave = .{},
    /// The caller commits scoped simulations together after staging every checkpoint.
    scope: ?*storage.Scope = null,
    memory_bytes: usize = std.math.maxInt(usize),
    temporary_bytes: usize = 16 * 1024,
    /// Borrowed scratch must outlive this simulation and remain exclusive during ticks and lifecycle hooks.
    scratch: ?[]u8 = null,
    /// Plugin metric capacity excludes the framework instruments counted from the composition.
    metrics: metrics.Registry.Configuration = .{ .capacity = 512 },
};

pub fn Simulation(comptime Selections: type) type {
    const count = plugin.selectedCount(Selections);
    const closing_tokens = plugin.closeTokenCount(Selections);
    return struct {
        const Self = @This();

        pub const State = enum { created, reserved, ready, ticking, failed, closing, closed };

        io: std.Io,
        state: State = .created,
        owned_scratch: ?[]align(64) u8,
        instances: plugin.Instances(Selections) = .{},
        permanent: PluginAllocator,
        temporary: std.heap.FixedBufferAllocator,
        metrics: metrics.Registry,
        plugin_metrics: [count]runtime.Instruments = undefined,
        server_tick: metrics.Timer = .{},
        server_work: metrics.Timer = .{},
        tick_duration: metrics.Timer = .{},
        checkpoint_duration: metrics.Timer = .{},
        checkpoint_cpu: metrics.Timer = .{},
        submit_duration: metrics.Timer = .{},
        close_hooks: metrics.Timer = .{},
        close_wait: metrics.Timer = .{},
        storage: *storage.Store,
        scope: ?*storage.Scope,
        transaction: storage.Transaction,
        completed_tick: u64,
        saved_tick: u64,
        autosave: Autosave,
        save_requested: Checkpoint = .{},
        closing: lifecycle.Closing = undefined,
        closing_slots: [closing_tokens]std.atomic.Value(bool) = undefined,
        plugin_bytes: [count]u64 = @splat(0),

        pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, configuration: Configuration) !*Self {
            if (configuration.autosave.ticks == 0) return error.InvalidAutosaveConfiguration;
            const scratch_bytes = if (configuration.scratch) |scratch| scratch.len else configuration.temporary_bytes;
            if (configuration.scratch == null and configuration.temporary_bytes > configuration.memory_bytes) return error.InvalidMemoryConfiguration;
            if (scratch_bytes < plugin.minimumTickScratchBytes(Selections)) return error.InvalidMemoryConfiguration;

            const owned_scratch_bytes = if (configuration.scratch == null) configuration.temporary_bytes else 0;
            if (configuration.memory_bytes < @sizeOf(Self) or owned_scratch_bytes > configuration.memory_bytes - @sizeOf(Self)) return error.OutOfMemory;
            const own_instruments = comptime blk: {
                var total: usize = 0;
                for (std.meta.fields(Self)) |field| if (field.type == metrics.Timer or field.type == metrics.Counter or field.type == metrics.Gauge) {
                    total += 1;
                };
                break :blk total;
            };
            var metrics_configuration = configuration.metrics;
            metrics_configuration.capacity = try std.math.add(usize, configuration.metrics.capacity, own_instruments + count * std.meta.fields(runtime.Instruments).len);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const owned_scratch = if (configuration.scratch == null) try allocator.alignedAlloc(u8, .@"64", owned_scratch_bytes) else null;
            errdefer if (owned_scratch) |bytes| allocator.free(bytes);
            if (configuration.scope) |scope| assert(scope.space.store == store);
            const transaction = if (configuration.scope) |scope| scope.transaction() else store.transaction();
            errdefer transaction.fail();
            self.* = .{
                .io = io,
                .owned_scratch = owned_scratch,
                .permanent = PluginAllocator.init(allocator, configuration.memory_bytes - @sizeOf(Self) - owned_scratch_bytes),
                .temporary = std.heap.FixedBufferAllocator.init(configuration.scratch orelse owned_scratch.?),
                .metrics = try metrics.Registry.init(allocator, io, metrics_configuration),
                .storage = store,
                .scope = configuration.scope,
                .transaction = transaction,
                .completed_tick = if (configuration.scope) |scope| scope.tick else store.lastTick(),
                .saved_tick = if (configuration.scope) |scope| scope.tick else store.lastTick(),
                .autosave = configuration.autosave,
            };
            errdefer self.metrics.deinit();
            errdefer self.permanent.deinit();
            try self.permanent.trackPlugins(&self.plugin_bytes);
            self.server_tick = try self.metrics.timer(.{ .name = "server.tick", .description = "Complete tick including session input and output publication" });
            self.server_work = try self.metrics.timer(.{ .name = "server.work", .description = "Between-tick storage progress and output publication" });
            self.tick_duration = try self.metrics.timer(.{ .name = "simulation.tick", .description = "Gameplay tick and storage submission" });
            self.checkpoint_duration = try self.metrics.timer(.{ .name = "simulation.checkpoint", .description = "Stage plugin state for submission" });
            self.checkpoint_cpu = try self.metrics.timer(.{ .name = "simulation.checkpoint.cpu", .description = "Plugin checkpoint work on the owning thread", .clock = .thread_cpu });
            self.submit_duration = try self.metrics.timer(.{ .name = "simulation.submit", .description = "Submit a complete simulation snapshot to storage" });
            self.close_hooks = try self.metrics.timer(.{ .name = "simulation.close.hooks", .description = "Invoke plugin close hooks" });
            self.close_wait = try self.metrics.timer(.{ .name = "simulation.close.wait", .description = "Wait for plugin close tokens" });
            assert(self.state == .created);
            return self;
        }

        pub fn initialize(self: *Self, selections: Selections, environment: anytype) !void {
            errdefer {
                self.state = .failed;
                self.transaction.fail();
            }
            try self.construct(false, selections, environment);
            self.state = .ready;
        }

        /// Construct configured capacity without restoring saved state.
        pub fn reserve(self: *Self, selections: Selections, environment: anytype) !void {
            try self.construct(true, selections, environment);
            self.state = .reserved;
        }

        fn construct(self: *Self, comptime reserve_only: bool, selections: Selections, environment: anytype) !void {
            assert(self.state == .created);
            errdefer self.state = .failed;
            const transaction = self.transaction;
            errdefer transaction.fail();
            try runtime.initialize(reserve_only, &self.instances, selections, &self.permanent, &self.metrics, &self.plugin_metrics, self.io, transaction, plugin.environment(.{ .checkpoint = &self.save_requested, .persistence = self.storage }, environment));
            self.metrics.seal();
            self.permanent.seal();
        }

        pub fn tick(self: *Self) !void {
            assert(self.state == .ready);
            const transaction = self.transaction;
            self.metrics.sequence.store(self.completed_tick + 1, .release);
            const duration = self.tick_duration.start();
            defer duration.end();
            self.state = .ticking;
            errdefer {
                self.transaction.fail();
                self.state = .failed;
            }
            const next_tick = try std.math.add(u64, self.completed_tick, 1);

            self.temporary.reset();
            runtime.beginTick(&self.instances);
            var tick_finished = false;
            defer if (!tick_finished) runtime.endTick(&self.instances, false);
            try runtime.tick(&self.instances, &self.temporary, &self.plugin_metrics, self.io, transaction);
            try transaction.progress();
            const scheduled = if (self.autosave.ticks) |interval| next_tick - self.saved_tick >= interval else false;
            self.completed_tick = next_tick;
            if (self.save_requested.requested or scheduled) {
                self.save_requested.requested = true;
                if (self.scope == null) try self.checkpoint(next_tick, true);
            }
            runtime.endTick(&self.instances, true);
            tick_finished = true;
            runtime.publish(&self.instances);
            self.temporary.reset();
            self.state = .ready;
            assert((if (self.scope) |scope| scope.tick else self.storage.lastTick()) == self.saved_tick);
            assert(self.saved_tick <= self.completed_tick);
        }

        pub fn get(self: *const Self, comptime Plugin: type) *Plugin {
            assert(self.state != .closed);
            return self.instances.get(Plugin);
        }

        pub fn poll(self: *Self) !void {
            assert(self.state == .ready);
            const work = self.server_work.start();
            defer work.end();
            errdefer {
                self.transaction.fail();
                self.state = .failed;
            }
            try self.transaction.progress();
            runtime.publish(&self.instances);
        }

        pub fn checkpointNow(self: *Self) !void {
            assert(self.state == .ready);
            assert(self.scope == null);
            errdefer {
                self.transaction.fail();
                self.state = .failed;
            }
            try self.checkpoint(self.completed_tick, true);
        }

        pub fn save(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            try self.checkpointNow();
            try self.storage.waitDurableUntil(self.storage.lastCommit(), deadline);
        }

        pub fn stageCheckpoint(self: *Self) !void {
            assert(self.state == .ready);
            assert(self.scope != null);
            errdefer {
                self.transaction.fail();
                self.state = .failed;
            }
            try self.serialize(self.completed_tick);
        }

        fn serialize(self: *Self, completed: u64) !void {
            const transaction = self.transaction;
            const duration = self.checkpoint_duration.start();
            defer duration.end();
            const cpu = self.checkpoint_cpu.start();
            defer cpu.end();
            try runtime.checkpoint(&self.instances, &self.temporary, &self.plugin_metrics, self.io, transaction);
            if (self.scope) |scope| try scope.setTick(completed);
            self.saved_tick = completed;
            self.save_requested.requested = false;
        }

        fn checkpoint(self: *Self, completed: u64, sync: bool) !void {
            assert(self.scope == null);
            try self.serialize(completed);
            {
                const duration = self.submit_duration.start();
                defer duration.end();
                const commit = try self.storage.commit(completed);
                if (sync) try self.storage.submitSync(commit);
            }
        }

        pub fn close(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            assert(self.scope == null);
            try self.finish(deadline, true);
        }

        pub fn unload(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            try self.finish(deadline, false);
        }

        fn finish(self: *Self, deadline: std.Io.Clock.Timestamp, durable: bool) !void {
            assert(self.state != .ticking);
            assert(self.state != .closed);

            if (self.state != .closing) {
                if (self.state == .created or self.state == .ready) {
                    errdefer self.state = .failed;
                    if (self.state == .created) self.transaction.fail();
                    if (self.state == .ready and (self.completed_tick > self.saved_tick or self.storage.hasWrites())) {
                        if (self.scope != null) try self.serialize(self.completed_tick) else try self.checkpoint(self.completed_tick, durable);
                    }
                }
                self.state = .closing;
                self.closing = lifecycle.Closing.init(self.io, deadline, &self.closing_slots);
                const hooks_started = self.close_hooks.start();
                runtime.close(&self.instances, self.io, &self.closing);
                hooks_started.end();
            }

            self.closing.deadline = deadline;
            const wait_started = self.close_wait.start();
            try self.closing.wait();
            wait_started.end();
            if (durable) try self.storage.waitDurableUntil(self.storage.lastCommit(), deadline);
            self.state = .closed;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            assert(self.state == .closed);
            self.metrics.deinit();
            self.permanent.deinit();
            if (self.owned_scratch) |bytes| allocator.free(bytes);
            allocator.destroy(self);
        }
    };
}
