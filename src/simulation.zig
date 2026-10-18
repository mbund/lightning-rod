const std = @import("std");
const plugin = @import("plugin.zig");
const runtime = @import("plugin_runtime.zig");
const PluginAllocator = @import("plugin_allocator.zig").PluginAllocator;
const metrics = @import("metrics");
const lifecycle = @import("plugin_lifecycle.zig");
const storage = @import("storage");
const Work = @import("work.zig").Work;
const Checkpoint = @import("checkpoint.zig").Checkpoint;

const assert = std.debug.assert;

/// Dirty cache evictions may write between checkpoints.
pub const Autosave = struct {
    ticks: ?u32 = 1200,
};

pub const Configuration = struct {
    autosave: Autosave = .{},
    memory_bytes: usize = 256 * 1024,
    temporary_bytes: usize = 16 * 1024,
    metrics: metrics.Registry.Configuration = .{ .capacity = 512 },
};

pub fn Simulation(comptime Selections: type) type {
    const count = plugin.selectedCount(Selections);
    const closing_tokens = plugin.closeTokenCount(Selections);
    return struct {
        const Self = @This();

        pub const State = enum { created, ready, ticking, failed, closing, closed };

        io: std.Io,
        state: State = .created,
        bytes: []align(64) u8,
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
        transaction: storage.Transaction,
        completed_tick: u64,
        saved_tick: u64,
        autosave: Autosave,
        save_requested: Checkpoint = .{},
        closing: lifecycle.Closing = undefined,
        closing_slots: [closing_tokens]std.atomic.Value(bool) = undefined,
        work: Work,
        work_overhead_ns: u64 = std.time.ns_per_ms,
        plugin_bytes: [count]u64 = @splat(0),

        pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *storage.Store, configuration: Configuration) !*Self {
            if (configuration.autosave.ticks == 0) return error.InvalidAutosaveConfiguration;
            if (configuration.temporary_bytes > configuration.memory_bytes) return error.InvalidMemoryConfiguration;
            if (configuration.temporary_bytes < plugin.minimumTickScratchBytes(Selections)) return error.InvalidMemoryConfiguration;

            const bytes = try allocator.alignedAlloc(u8, .@"64", configuration.memory_bytes);
            errdefer allocator.free(bytes);
            const end = bytes.len - configuration.temporary_bytes;
            var bootstrap = std.heap.FixedBufferAllocator.init(bytes[0..end]);
            const self = try bootstrap.allocator().create(Self);
            const tasks = try bootstrap.allocator().alloc(Work.Task, count);
            const transaction = store.transaction();
            errdefer transaction.fail();
            self.* = .{
                .io = io,
                .bytes = bytes,
                .permanent = PluginAllocator.init(bytes[bootstrap.end_index..end]),
                .temporary = std.heap.FixedBufferAllocator.init(bytes[end..]),
                .metrics = try metrics.Registry.init(allocator, io, configuration.metrics),
                .work = .{ .tasks = tasks },
                .storage = store,
                .transaction = transaction,
                .completed_tick = store.lastTick(),
                .saved_tick = store.lastTick(),
                .autosave = configuration.autosave,
            };
            errdefer self.metrics.deinit();
            self.permanent.trackPlugins(&self.plugin_bytes);
            self.server_tick = try self.metrics.timer(.{ .name = "server.tick", .description = "Complete tick including session input and output publication" });
            self.server_work = try self.metrics.timer(.{ .name = "server.work", .description = "Background work including output publication" });
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
            assert(self.state == .created);
            errdefer self.state = .failed;
            const transaction = self.transaction;
            errdefer transaction.fail();
            try runtime.initialize(&self.instances, selections, &self.permanent, &self.metrics, &self.plugin_metrics, self.io, transaction, &self.work, plugin.environment(.{ .checkpoint = &self.save_requested }, environment));
            self.work.registration_timer = .{};
            self.metrics.seal();
            self.work.sealed = true;
            self.permanent.seal();
            self.state = .ready;
        }

        pub fn tick(self: *Self) !void {
            assert(self.state == .ready);
            const transaction = self.transaction;
            self.metrics.sequence = self.completed_tick + 1;
            const duration = self.tick_duration.start();
            defer duration.end();
            self.state = .ticking;
            errdefer {
                self.transaction.fail();
                self.state = .failed;
            }
            const next_tick = try std.math.add(u64, self.completed_tick, 1);

            self.temporary.reset();
            try runtime.tick(&self.instances, &self.temporary, &self.plugin_metrics, self.io, transaction);
            try transaction.progress();
            const scheduled = if (self.autosave.ticks) |interval| next_tick - self.saved_tick >= interval else false;
            self.completed_tick = next_tick;
            if (self.save_requested.requested or scheduled) {
                try self.checkpoint(next_tick);
            }
            self.work.beginTick();
            self.work_overhead_ns = @max(std.time.ns_per_ms, self.work_overhead_ns - self.work_overhead_ns / 8);
            self.temporary.reset();
            self.state = .ready;
            assert(self.storage.lastTick() == self.saved_tick);
            assert(self.saved_tick <= self.completed_tick);
        }

        pub fn get(self: *const Self, comptime Plugin: type) *Plugin {
            assert(self.state != .closed);
            return self.instances.get(Plugin);
        }

        /// Background I/O does not run gameplay hooks. Staged writes publish only
        /// with a complete plugin checkpoint at a simulation boundary.
        pub fn progress(self: *Self, deadline: i96) !Work.Result {
            assert(self.state == .ready);
            const started = std.Io.Clock.now(.awake, self.io).nanoseconds;
            if (deadline - started <= self.work_overhead_ns) return .idle;
            const transaction = self.transaction;
            errdefer {
                self.transaction.fail();
                self.state = .failed;
            }

            const running = std.Io.Clock.now(.awake, self.io).nanoseconds;
            const result = try self.work.progress(self.io, deadline - self.work_overhead_ns);
            const finished = std.Io.Clock.now(.awake, self.io).nanoseconds;
            if (result == .progressed) try transaction.progress();
            const overhead: u64 = @intCast(running - started + std.Io.Clock.now(.awake, self.io).nanoseconds - finished);
            self.work_overhead_ns = @max(self.work_overhead_ns, overhead);
            if (result == .idle and deadline - std.Io.Clock.now(.awake, self.io).nanoseconds > self.work_overhead_ns) {
                if (try self.storage.maintain(8) == .progressed) return .progressed;
            }
            return result;
        }

        fn checkpoint(self: *Self, completed: u64) !void {
            const transaction = self.transaction;
            {
                const duration = self.checkpoint_duration.start();
                defer duration.end();
                const cpu = self.checkpoint_cpu.start();
                defer cpu.end();
                try runtime.checkpoint(&self.instances, &self.temporary, &self.plugin_metrics, self.io, transaction);
            }
            {
                const duration = self.submit_duration.start();
                defer duration.end();
                const commit = try self.storage.commit(completed);
                try self.storage.submitSync(commit);
            }
            self.saved_tick = completed;
            self.save_requested.requested = false;
        }

        pub fn close(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            assert(self.state != .ticking);
            assert(self.state != .closed);

            if (self.state != .closing) {
                if (self.state == .created or self.state == .ready) {
                    errdefer self.state = .failed;
                    if (self.state == .created) self.transaction.fail();
                    if (self.state == .ready and (self.completed_tick > self.saved_tick or self.storage.hasWrites())) try self.checkpoint(self.completed_tick);
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
            try self.storage.waitDurableUntil(self.storage.lastCommit(), deadline);
            self.state = .closed;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            assert(self.state == .closed);
            const bytes = self.bytes;
            self.metrics.deinit();
            allocator.free(bytes);
        }
    };
}
