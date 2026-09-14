const std = @import("std");

const assert = std.debug.assert;
const plugin = @import("plugin.zig");
const runtime = @import("plugin_runtime.zig");
const memory = @import("memory.zig");
const metrics = @import("metrics.zig");
const lifecycle = @import("plugin_lifecycle.zig");
const storage = @import("storage");
const Work = @import("work.zig").Work;

pub const Configuration = struct {
    memory_bytes: usize = 256 * 1024,
    temporary_bytes: usize = 16 * 1024,
    profiling: bool = true,
};

pub fn Simulation(comptime Selections: type) type {
    const count = plugin.selectedCount(Selections);
    const traces = plugin.traceCount(Selections);
    const closing_tokens = plugin.closeTokenCount(Selections);
    return struct {
        const Self = @This();

        pub const State = enum { created, ready, ticking, failed, closing, closed };

        io: std.Io,
        state: State = .created,
        bytes: []align(64) u8,
        instances: runtime.Instances(Selections) = .{},
        permanent: memory.Allocator,
        temporary: std.heap.FixedBufferAllocator,
        measurements: metrics.Metrics,
        storage: storage.Storage,
        transaction: ?storage.Transaction = null,
        completed_tick: u64,
        last_tick_ns: u64 = 0,
        maximum_tick_ns: u64 = 0,
        simulation_ns: u64 = 0,
        checkpoint_ns: u64 = 0,
        submit_ns: u64 = 0,
        closing: lifecycle.Closing = undefined,
        closing_slots: [closing_tokens]std.atomic.Value(bool) = undefined,
        work: Work,
        work_ns: u64 = 0,
        maximum_work_ns: u64 = 0,
        plugin_bytes: [count]u64 = @splat(0),

        pub fn init(allocator: std.mem.Allocator, io: std.Io, store: storage.Storage, configuration: Configuration) !*Self {
            if (configuration.temporary_bytes > configuration.memory_bytes) return error.InvalidMemoryConfiguration;
            if (configuration.temporary_bytes < plugin.minimumTickScratchBytes(Selections)) return error.InvalidMemoryConfiguration;

            const bytes = try allocator.alignedAlloc(u8, .@"64", configuration.memory_bytes);
            errdefer allocator.free(bytes);
            const end = bytes.len - configuration.temporary_bytes;
            var bootstrap = std.heap.FixedBufferAllocator.init(bytes[0..end]);
            const self = try bootstrap.allocator().create(Self);
            const measurements = try metrics.Metrics.init(bootstrap.allocator(), io, count, traces, configuration.profiling);
            const tasks = try bootstrap.allocator().alloc(Work.Task, count);
            self.* = .{
                .io = io,
                .bytes = bytes,
                .permanent = memory.Allocator.init(bytes[bootstrap.end_index..end]),
                .temporary = std.heap.FixedBufferAllocator.init(bytes[end..]),
                .measurements = measurements,
                .work = .{ .tasks = tasks },
                .storage = store,
                .completed_tick = store.lastTick(),
            };
            self.permanent.trackPlugins(&self.plugin_bytes);
            assert(self.state == .created);
            assert(self.transaction == null);
            return self;
        }

        pub fn initialize(self: *Self, selections: Selections, environment: anytype) !void {
            assert(self.state == .created);
            errdefer {
                if (self.transaction) |transaction| transaction.abort();
                self.transaction = null;
                self.state = .failed;
            }
            self.transaction = try self.storage.begin(self.io, try std.math.add(u64, self.completed_tick, 1));
            try runtime.initialize(&self.instances, selections, &self.permanent, &self.measurements, self.io, self.transaction.?, &self.work, environment);
            self.work.sealed = true;
            self.permanent.seal();
            self.state = .ready;
        }

        pub fn tick(self: *Self) !void {
            assert(self.state == .ready);
            const started = std.Io.Clock.now(.awake, self.io);
            defer {
                const ended = std.Io.Clock.now(.awake, self.io);
                assert(ended.nanoseconds >= started.nanoseconds);
                self.last_tick_ns = @intCast(ended.nanoseconds - started.nanoseconds);
                self.maximum_tick_ns = @max(self.maximum_tick_ns, self.last_tick_ns);

                if (self.state == .ready)
                    self.measurements.completed_tick = .{
                        .sequence = self.completed_tick,
                        .ended_ns = ended.nanoseconds,
                        .duration_ns = self.last_tick_ns,
                    };
            }
            self.state = .ticking;
            errdefer {
                if (self.transaction) |transaction| transaction.abort();
                self.transaction = null;
                self.state = .failed;
            }
            const next_tick = try std.math.add(u64, self.completed_tick, 1);

            if (self.transaction == null) self.transaction = try self.storage.begin(self.io, next_tick);
            self.temporary.reset();
            try runtime.tick(&self.instances, &self.temporary, &self.measurements, self.io, self.transaction.?);
            const simulated = std.Io.Clock.now(.awake, self.io);
            self.simulation_ns = @intCast(simulated.nanoseconds - started.nanoseconds);
            try runtime.checkpoint(&self.instances, self.io, self.transaction.?);
            const staged = std.Io.Clock.now(.awake, self.io);
            self.checkpoint_ns = @intCast(staged.nanoseconds - simulated.nanoseconds);
            try self.transaction.?.submit();
            self.submit_ns = @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds - staged.nanoseconds);
            self.transaction = null;
            self.completed_tick = next_tick;
            self.temporary.reset();
            self.state = .ready;
            assert(self.storage.lastTick() == self.completed_tick);
        }

        pub fn get(self: *const Self, comptime Plugin: type) *Plugin {
            assert(self.state != .closed);
            return self.instances.get(Plugin);
        }

        /// Run between ticks. Writes join the next tick's transaction. They are submitted only
        /// after that entire gameplay tick and checkpoint succeed.
        pub fn progress(self: *Self) !Work.Result {
            assert(self.state == .ready);
            const started = std.Io.Clock.now(.awake, self.io).nanoseconds;
            defer {
                self.work_ns = @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds - started);
                self.maximum_work_ns = @max(self.maximum_work_ns, self.work_ns);
            }
            errdefer {
                if (self.transaction) |transaction| transaction.abort();
                self.transaction = null;
                self.state = .failed;
            }

            if (self.transaction == null) self.transaction = try self.storage.begin(self.io, try std.math.add(u64, self.completed_tick, 1));
            return self.work.progress(self.io);
        }

        pub fn close(self: *Self, deadline: std.Io.Clock.Timestamp) !void {
            assert(self.state != .ticking);
            assert(self.state != .closed);

            if (self.state != .closing) {
                if (self.transaction) |transaction| transaction.abort();
                self.transaction = null;
                self.state = .closing;
                self.closing = lifecycle.Closing.init(self.io, deadline, &self.closing_slots);
                runtime.close(&self.instances, self.io, &self.closing);
            }

            self.closing.deadline = deadline;
            try self.closing.wait();
            self.state = .closed;
            try self.storage.flush(self.io);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            assert(self.state == .closed);
            assert(self.transaction == null);
            const bytes = self.bytes;
            allocator.free(bytes);
        }
    };
}
