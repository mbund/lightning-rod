const generation_allocator = @import("../generation_allocator.zig");
const lifecycle = @import("../plugin_lifecycle.zig");
const persistence = @import("../persistence.zig");
const plugin_profiler = @import("../plugin_profiler.zig");
const plugin_runtime = @import("../plugin_runtime.zig");
const plugin = @import("../plugin.zig");
const preallocated = @import("preallocated");
const runtime = @import("../runtime/contracts.zig");
const std = @import("std");
const tick_arena = @import("../tick_arena.zig");
const builtin = @import("builtin");

pub const Configuration = struct {
    memory_bytes: usize,
    /// Zero requires caller-owned scratch through tickWithScratch or tickUsing.
    tick_bytes: usize,
    profiling: bool = true,

    pub fn validate(self: Configuration) !void {
        if (self.memory_bytes == 0 or self.tick_bytes >= self.memory_bytes)
            return error.InvalidCapacity;
    }
};

pub const Memory = struct {
    capacity_bytes: usize,
    generation_capacity_bytes: usize,
    generation_used_bytes: usize,
    tick_capacity_bytes: usize,

    pub fn usedBytes(self: Memory) usize {
        return self.generation_used_bytes + self.tick_capacity_bytes;
    }

    pub fn generationHeadroomBytes(self: Memory) usize {
        return self.generation_capacity_bytes - self.generation_used_bytes;
    }

    pub fn headroomBytes(self: Memory) usize {
        return self.capacity_bytes - self.usedBytes();
    }
};

pub fn Composition(comptime Selections: type) type {
    plugin.validate(Selections);
    const plugin_count = plugin.selectedCount(Selections);
    const trace_count = plugin.traceCount(Selections);
    const closing_token_count = plugin.closeTokenCount(Selections);

    return struct {
        const Self = @This();
        pub const minimum_tick_scratch_bytes = plugin.minimumTickScratchBytes(Selections);

        instances: plugin_runtime.Instances(Selections),
        io: std.Io,
        storage: []u8,
        fixed_overhead_bytes: usize,
        generation: generation_allocator.Allocator,
        temporary: ?*tick_arena.Arena,
        profiler: plugin_profiler.Profiler,
        persistence: persistence.Interface,
        checkpoint_writer: lifecycle.Checkpoint.Writer,
        closing_storage: []std.atomic.Value(u8),
        closing: lifecycle.Closing = undefined,
        closing_started: bool = false,
        initialization_attempted: bool = false,
        failed: bool = false,

        pub fn create(
            allocator: std.mem.Allocator,
            io: std.Io,
            persistence_interface: persistence.Interface,
            configuration: Configuration,
            counter: ?plugin_profiler.Counter,
        ) !*Self {
            try configuration.validate();
            if (configuration.tick_bytes != 0 and configuration.tick_bytes < minimum_tick_scratch_bytes)
                return error.InvalidTickScratchCapacity;
            const storage = try preallocated.alloc(u8, allocator, configuration.memory_bytes);
            errdefer allocator.free(storage);
            const generation_end = configuration.memory_bytes - configuration.tick_bytes;
            var bootstrap = std.heap.FixedBufferAllocator.init(storage[0..generation_end]);
            const bootstrap_allocator = bootstrap.allocator();
            const self = bootstrap_allocator.create(Self) catch
                return error.ConfiguredMemoryMaximumExceeded;
            var measurements: plugin_profiler.Profiler = .{};
            measurements.allocate(bootstrap_allocator, plugin_count, trace_count) catch
                return error.ConfiguredMemoryMaximumExceeded;
            const closing_storage = bootstrap_allocator.alloc(std.atomic.Value(u8), @max(closing_token_count, 1)) catch
                return error.ConfiguredMemoryMaximumExceeded;
            const temporary = if (configuration.tick_bytes == 0) null else tick_arena.Arena.createIn(
                bootstrap_allocator,
                storage[generation_end..],
            ) catch return error.ConfiguredMemoryMaximumExceeded;
            const fixed_overhead_bytes = bootstrap.end_index;
            if (fixed_overhead_bytes >= generation_end)
                return error.ConfiguredMemoryMaximumExceeded;
            self.* = .{
                .instances = .{},
                .io = io,
                .storage = storage,
                .fixed_overhead_bytes = fixed_overhead_bytes,
                .generation = generation_allocator.Allocator.init(storage[fixed_overhead_bytes..generation_end]),
                .temporary = temporary,
                .profiler = measurements,
                .persistence = persistence_interface,
                .checkpoint_writer = lifecycle.Checkpoint.Writer.init(persistence_interface, io),
                .closing_storage = closing_storage,
            };
            if (counter) |value| self.profiler.setCounter(value);
            self.profiler.setEnabled(configuration.profiling) catch
                return error.ProfilingCounterRequired;
            self.generation.trackPlugins(self.profiler.generationMemory());
            self.closing = lifecycle.Closing.init(0, self.closing_storage);
            return self;
        }

        pub fn initialize(self: *Self, selections: Selections, environment: anytype) !void {
            std.debug.assert(!self.initialization_attempted and !self.closing_started);
            self.initialization_attempted = true;
            plugin_runtime.initialize(
                Selections,
                &self.instances,
                selections,
                &self.generation,
                &self.profiler,
                self.io,
                environment,
            ) catch |err| {
                if (@as(anyerror, err) == error.OutOfMemory)
                    return error.ConfiguredMemoryMaximumExceeded;
                return err;
            };
            self.publishMemory();
            const snapshot = self.profiler.snapshot();
            for (snapshot.plugins[0..snapshot.plugin_count]) |item| {
                if (item.generation_bytes < 64 * 1024) continue;
                std.log.info("event=plugin_memory plugin={s} generation_bytes={d}", .{
                    item.id_ptr[0..item.id_len],
                    item.generation_bytes,
                });
            }
        }

        pub fn finishInitialization(self: *Self) void {
            std.debug.assert(!self.generation.sealed);
            std.debug.assert(self.instances.initialized == plugin_count and !self.closing_started);
            self.generation.seal();
            std.debug.assert(self.memory().usedBytes() <= self.storage.len);
        }

        pub fn tick(self: *Self) runtime.Outcome {
            return self.tickWithScratch(self.temporary orelse return .failed);
        }

        pub fn tickWithScratch(self: *Self, scratch: *tick_arena.Arena) runtime.Outcome {
            if (scratch.bytes.len < minimum_tick_scratch_bytes) return .failed;
            const temporary = scratch.begin();
            defer scratch.finish();
            return self.tickUsing(temporary);
        }

        pub fn tickUsing(self: *Self, temporary: std.mem.Allocator) runtime.Outcome {
            std.debug.assert(self.generation.sealed);
            if (self.failed or self.closing_started) return .failed;
            if (self.persistence.poisoned()) {
                self.markFailed();
                return .failed;
            }
            const test_started = if (comptime builtin.is_test)
                std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds
            else
                0;
            plugin_runtime.tick(Selections, &self.instances, temporary, &self.profiler, self.io) catch {
                self.markFailed();
                return .failed;
            };
            if (self.persistence.poisoned()) {
                self.markFailed();
                return .failed;
            }
            if (self.profiler.enabled and self.profiler.tick_last_ns > runtime.maximum_tick_ns) {
                const snapshot = self.profiler.snapshot();
                var slowest: [3]?usize = @splat(null);
                var accounted_ns: u64 = 0;
                for (snapshot.plugins[0..snapshot.plugin_count], 0..) |timing, index| {
                    accounted_ns += timing.last_ns;
                    var candidate: ?usize = index;
                    for (&slowest) |*rank| {
                        if (candidate == null) break;
                        if (rank.* == null or snapshot.plugins[candidate.?].last_ns > snapshot.plugins[rank.*.?].last_ns)
                            std.mem.swap(?usize, rank, &candidate);
                    }
                }
                std.log.warn("event=slow_plugin_tick tick={d} elapsed_us={d} accounted_us={d}", .{
                    self.profiler.tick_count,
                    self.profiler.tick_last_ns / std.time.ns_per_us,
                    accounted_ns / std.time.ns_per_us,
                });
                for (slowest, 1..) |entry, rank| {
                    const index = entry orelse break;
                    const timing = snapshot.plugins[index];
                    if (timing.last_ns == 0) break;
                    std.log.warn("event=slow_plugin tick={d} rank={d} plugin={s} elapsed_us={d} temporary_bytes={d}", .{
                        self.profiler.tick_count,
                        rank,
                        timing.id_ptr[0..timing.id_len],
                        timing.last_ns / std.time.ns_per_us,
                        timing.tick_memory_last_bytes,
                    });
                }
                var slowest_traces: [3]?usize = @splat(null);
                for (snapshot.traces[0..snapshot.trace_count], 0..) |trace, index| {
                    if (trace.last_ns < std.time.ns_per_ms) continue;
                    var candidate: ?usize = index;
                    for (&slowest_traces) |*rank| {
                        if (candidate == null) break;
                        if (rank.* == null or snapshot.traces[candidate.?].last_ns > snapshot.traces[rank.*.?].last_ns)
                            std.mem.swap(?usize, rank, &candidate);
                    }
                }
                for (slowest_traces) |entry| {
                    const trace = snapshot.traces[entry orelse break];
                    const owner = snapshot.plugins[trace.plugin_index];
                    std.log.warn("event=slow_plugin_trace tick={d} plugin={s} scope={s} elapsed_us={d} calls={d}", .{
                        self.profiler.tick_count,
                        owner.id_ptr[0..owner.id_len],
                        trace.name(),
                        trace.last_ns / std.time.ns_per_us,
                        trace.last_calls,
                    });
                }
            }
            if (comptime builtin.is_test) {
                const elapsed: u64 = @intCast(std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds - test_started);
                if (elapsed > runtime.maximum_tick_ns)
                    std.debug.panic("test tick exceeded 50ms: {d}us", .{elapsed / std.time.ns_per_us});
            }
            self.publishMemory();
            return .ok;
        }

        pub fn captureCheckpoint(self: *Self) runtime.CheckpointCapture {
            std.debug.assert(self.generation.sealed);
            if (self.failed) return .failed;
            switch (self.persistence.checkpointProgress()) {
                .ready => {},
                .pending, .backpressured => {
                    switch (self.persistence.flush()) {
                        .ready, .pending, .backpressured => return .busy,
                        .failed, .missing, .too_small => {
                            self.markFailed();
                            return .failed;
                        },
                    }
                },
                .failed, .missing, .too_small => {
                    self.markFailed();
                    return .failed;
                },
            }
            if (self.stageCheckpoint() == .failed) return .failed;
            return switch (self.persistence.requestCheckpoint()) {
                .ready, .pending => .captured,
                .backpressured => .busy,
                .failed, .missing, .too_small => failed: {
                    self.markFailed();
                    break :failed .failed;
                },
            };
        }

        /// The caller must hold this Core idle until the shared checkpoint is
        /// committed. If any participant fails, do not commit the partial cut.
        pub fn stageCheckpoint(self: *Self) runtime.Outcome {
            std.debug.assert(self.generation.sealed);
            if (self.failed or self.persistence.poisoned()) {
                self.markFailed();
                return .failed;
            }
            plugin_runtime.checkpoint(
                &self.instances,
                &self.checkpoint_writer,
                &self.profiler,
                self.io,
            ) catch {
                self.markFailed();
                return .failed;
            };
            if (self.persistence.poisoned()) {
                self.markFailed();
                return .failed;
            }
            return .ok;
        }

        pub fn markFailed(self: *Self) void {
            self.failed = true;
        }

        pub fn checkpointProgress(self: *Self) runtime.Progress {
            if (self.failed) return .failed;
            return switch (self.persistence.checkpointProgress()) {
                .ready => .complete,
                .pending, .backpressured => .pending,
                .failed, .missing, .too_small => failed: {
                    self.markFailed();
                    break :failed .failed;
                },
            };
        }

        pub fn beginClose(self: *Self, deadline_ns: i128) runtime.Outcome {
            if (self.closing_started) return .ok;
            const wake = self.closing.wake;
            self.closing = lifecycle.Closing.init(deadline_ns, self.closing_storage);
            self.closing.preserveWake(wake);
            plugin_runtime.close(&self.instances, &self.closing, &self.profiler, self.io);
            self.closing_started = true;
            return .ok;
        }

        pub fn readiness(self: *Self) runtime.Readiness {
            return self.closing.readiness();
        }

        pub fn closeProgress(self: *const Self) runtime.Progress {
            if (!self.closing_started) return .pending;
            return if (self.closing.complete()) .complete else .pending;
        }

        pub inline fn get(self: *Self, comptime Plugin: type) *Plugin {
            return plugin_runtime.get(&self.instances, Plugin);
        }

        pub fn generationBytes(self: *const Self) usize {
            return self.generation.used();
        }

        pub fn memory(self: *const Self) Memory {
            const tick_capacity = if (self.temporary) |arena| arena.bytes.len else 0;
            return .{
                .capacity_bytes = self.storage.len,
                .generation_capacity_bytes = self.storage.len - tick_capacity,
                .generation_used_bytes = self.fixed_overhead_bytes + self.generation.used(),
                .tick_capacity_bytes = tick_capacity,
            };
        }

        fn publishMemory(self: *Self) void {
            const value = self.memory();
            self.profiler.setMemory(value.capacity_bytes, value.generation_used_bytes, value.tick_capacity_bytes);
        }
    };
}

test "backend failure permanently stops a composition" {
    const State = struct {
        pub const id = "test:checkpoint_failure";
        pub const Configuration = struct {};
        ticks: usize = 0,
        checkpoints: usize = 0,
        failing_store: ?*persistence.Store = null,

        pub fn init(allocator: std.mem.Allocator, _: @This().Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }

        pub fn tick(self: *@This()) void {
            self.ticks += 1;
            if (self.failing_store) |store| store.markFailed();
        }

        pub fn checkpoint(self: *@This(), writer: *lifecycle.Checkpoint.NamespaceWriter) !void {
            self.checkpoints += 1;
            try writer.put("state", "committed tick");
            if (self.failing_store) |store| store.markFailed();
        }
    };
    const Fault = struct {
        fn progress(_: *anyopaque) persistence.Status {
            return .failed;
        }
    };
    const selected = .{plugin.configured(State, State.Configuration{})};
    const Core = Composition(@TypeOf(selected));
    for (0..5) |boundary| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const store = try persistence.Store.initForTest(arena.allocator(), .{
            .maximum_keys = 1,
            .maximum_checkpoint_records = 1,
            .maximum_requests = 1,
            .maximum_namespace_bytes = 32,
            .maximum_key_bytes = 16,
            .maximum_value_bytes = 32,
            .maximum_checkpoint_bytes = 256,
        }, 1024);
        const original = store.interface();
        var vtable = original.vtable.*;
        const core = try Core.create(arena.allocator(), std.testing.io, .{
            .context = original.context,
            .vtable = &vtable,
        }, .{ .memory_bytes = 64 * 1024, .tick_bytes = 128, .profiling = false }, null);
        try core.initialize(selected, .{ .meta = .{} });
        core.finishInitialization();
        try std.testing.expectEqual(runtime.Outcome.ok, core.tick());
        if (boundary >= 3) {
            core.get(State).failing_store = store;
        } else if (boundary == 1) {
            vtable.request_checkpoint = Fault.progress;
        } else vtable.checkpoint_progress = Fault.progress;
        if (boundary == 4) {
            try std.testing.expectEqual(runtime.Outcome.failed, core.stageCheckpoint());
        } else if (boundary == 3) {
            try std.testing.expectEqual(runtime.Outcome.failed, core.tick());
        } else if (boundary == 2) {
            try std.testing.expectEqual(runtime.Progress.failed, core.checkpointProgress());
        } else try std.testing.expectEqual(runtime.CheckpointCapture.failed, core.captureCheckpoint());
        vtable = original.vtable.*;
        core.get(State).failing_store = null;
        store.poisoned_storage = false;
        try std.testing.expect(!store.poisoned());
        try std.testing.expectEqual(runtime.Outcome.failed, core.tick());
        try std.testing.expectEqual(runtime.CheckpointCapture.failed, core.captureCheckpoint());
        try std.testing.expectEqual(runtime.Progress.failed, core.checkpointProgress());
        try std.testing.expectEqual(@as(usize, if (boundary == 3) 2 else 1), core.get(State).ticks);
        try std.testing.expectEqual(@as(usize, @intFromBool(boundary == 1 or boundary == 4)), core.get(State).checkpoints);
        try std.testing.expect(!store.checkpoint_requested);
        try std.testing.expectEqual(@as(usize, 0), store.test_storage_len);
        try std.testing.expectEqual(runtime.Outcome.ok, core.beginClose(0));
        try std.testing.expectEqual(runtime.Progress.complete, core.closeProgress());
    }
}

test "composition checkpoints only after all plugin callbacks succeed" {
    const State = struct {
        pub const id = "test:state";
        pub const Configuration = struct {};
        pub const tick_scratch_bytes = 128;
        value: u8 = 0,
        fail: bool = false,

        pub fn init(allocator: std.mem.Allocator, _: @This().Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }

        pub fn tick(self: *@This(), temporary: std.mem.Allocator) lifecycle.FatalError!void {
            _ = temporary.alloc(u8, 128) catch unreachable;
            self.value += 1;
            if (self.fail) return error.StorageReadFailed;
        }

        pub fn checkpoint(self: *@This(), writer: *lifecycle.Checkpoint.NamespaceWriter) !void {
            try writer.put("value", &.{self.value});
        }
    };
    const Later = struct {
        pub const id = "test:later";
        pub const Configuration = struct {};
        fail: bool = false,

        pub fn init(allocator: std.mem.Allocator, _: @This().Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }

        pub fn checkpoint(self: *@This(), _: *lifecycle.Checkpoint.NamespaceWriter) !void {
            if (self.fail) return error.InjectedCheckpointFailure;
        }
    };
    const selected = .{ plugin.configured(State, State.Configuration{}), plugin.configured(Later, Later.Configuration{}) };
    const Store = persistence.Store;
    var memory: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initForTest(fixed.allocator(), .{
        .maximum_keys = 4,
        .maximum_checkpoint_records = 4,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 32,
        .maximum_key_bytes = 16,
        .maximum_value_bytes = 32,
        .maximum_checkpoint_bytes = 256,
    }, 1024);
    const Core = Composition(@TypeOf(selected));
    const before_rejection = fixed.end_index;
    try std.testing.expectError(error.InvalidTickScratchCapacity, Core.create(
        fixed.allocator(),
        std.testing.io,
        store.interface(),
        .{ .memory_bytes = 64 * 1024, .tick_bytes = 127, .profiling = false },
        null,
    ));
    try std.testing.expectEqual(before_rejection, fixed.end_index);
    const core = try Core.create(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        store.interface(),
        .{ .memory_bytes = 64 * 1024, .tick_bytes = 128, .profiling = false },
        null,
    );
    try core.initialize(selected, .{ .meta = .{} });
    core.finishInitialization();
    const external = try Core.create(
        fixed.allocator(),
        std.testing.io,
        store.interface(),
        .{ .memory_bytes = 64 * 1024, .tick_bytes = 0, .profiling = false },
        null,
    );
    try external.initialize(selected, .{ .meta = .{} });
    external.finishInitialization();
    const undersized = try tick_arena.Arena.create(fixed.allocator(), 127);
    try std.testing.expectEqual(runtime.Outcome.failed, external.tickWithScratch(undersized));
    try std.testing.expectEqual(@as(u8, 0), external.get(State).value);
    try std.testing.expect(!undersized.active);
    try std.testing.expectEqual(@as(usize, 0), undersized.fixed.end_index);
    const scratch = try tick_arena.Arena.create(fixed.allocator(), 128);
    try std.testing.expectEqual(@as(usize, 0), external.memory().tick_capacity_bytes);
    try std.testing.expectEqual(@as(usize, 64 * 1024), external.memory().generation_capacity_bytes);
    try std.testing.expectEqual(runtime.Outcome.failed, external.tick());
    try std.testing.expectEqual(@as(u8, 0), external.get(State).value);
    for (0..4) |_| {
        try std.testing.expectEqual(runtime.Outcome.ok, external.tickWithScratch(scratch));
        try std.testing.expect(!scratch.active);
        try std.testing.expectEqual(@as(usize, 0), scratch.fixed.end_index);
    }
    external.get(State).fail = true;
    try std.testing.expectEqual(runtime.Outcome.failed, external.tickWithScratch(scratch));
    try std.testing.expect(!scratch.active);
    try std.testing.expectEqual(@as(usize, 0), scratch.fixed.end_index);
    try std.testing.expectEqual(@as(u8, 5), external.get(State).value);
    external.get(State).fail = false;
    try std.testing.expectEqual(runtime.Outcome.failed, external.tickWithScratch(scratch));
    try std.testing.expectEqual(@as(u8, 5), external.get(State).value);
    try std.testing.expectEqual(runtime.Outcome.failed, external.stageCheckpoint());
    try std.testing.expectEqual(runtime.CheckpointCapture.failed, external.captureCheckpoint());
    try std.testing.expectEqual(@as(usize, 0), store.stagedRecords());
    try std.testing.expectEqual(runtime.Outcome.ok, external.beginClose(0));
    try std.testing.expectEqual(runtime.Progress.complete, external.closeProgress());
    try std.testing.expectEqual(@as(u8, 0), core.get(State).value);
    try std.testing.expectEqual(runtime.Outcome.ok, core.tick());
    const memory_report = core.memory();
    try std.testing.expectEqual(@as(usize, 64 * 1024), memory_report.capacity_bytes);
    try std.testing.expect(memory_report.usedBytes() <= memory_report.capacity_bytes);
    try std.testing.expectEqual(
        core.fixed_overhead_bytes + core.generation.used() + core.temporary.?.bytes.len,
        memory_report.usedBytes(),
    );
    try std.testing.expectEqual(persistence.Status.ready, store.interface().stage(.{ .namespace = "runtime", .key = "pending", .operation = .{ .put = "accepted" } }));
    try std.testing.expectEqual(@as(usize, 0), store.checkpointBytes().len);
    try std.testing.expectEqual(runtime.CheckpointCapture.busy, core.captureCheckpoint());
    try std.testing.expect(store.checkpointBytes().len != 0);
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(runtime.CheckpointCapture.captured, core.captureCheckpoint());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(runtime.Progress.complete, core.checkpointProgress());
    const committed_bytes = store.test_storage_len;
    core.get(Later).fail = true;
    try std.testing.expectEqual(runtime.Outcome.ok, core.tick());
    try std.testing.expectEqual(runtime.CheckpointCapture.failed, core.captureCheckpoint());
    core.get(Later).fail = false;
    try std.testing.expectEqual(runtime.Outcome.failed, core.tick());
    try std.testing.expectEqual(runtime.CheckpointCapture.failed, core.captureCheckpoint());
    try std.testing.expect(!store.checkpoint_requested);
    try std.testing.expectEqual(committed_bytes, store.test_storage_len);
    var staged: [1]u8 = undefined;
    const request = store.read(State.id, "value", &staged);
    try std.testing.expectEqual(persistence.Status.ready, store.pollRead(request).status);
    try std.testing.expectEqual(@as(u8, 2), staged[0]);
    const recovered = try Store.initIndex(fixed.allocator(), store.configuration);
    try std.testing.expectEqual(committed_bytes, try recovered.recover(store.test_storage[0..committed_bytes]));
    const location = recovered.startupLocation(State.id, "value").?;
    try std.testing.expectEqual(@as(u8, 1), store.test_storage[@intCast(location.offset)]);
}

test "composition fails before serving when fixed Core storage exceeds its reservation" {
    const State = struct {
        pub const id = "test:reservation";
        pub const Configuration = struct {};

        pub fn init(allocator: std.mem.Allocator, _: @This().Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }
    };
    const selected = .{plugin.configured(State, State.Configuration{})};
    var memory: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try persistence.Store.initForTest(fixed.allocator(), .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 128,
    }, 128);
    const Core = Composition(@TypeOf(selected));
    try std.testing.expectError(error.ConfiguredMemoryMaximumExceeded, Core.create(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        store.interface(),
        .{ .memory_bytes = 256, .tick_bytes = 128, .profiling = true },
        null,
    ));
}

test "enabled composition profiling requires a host counter" {
    const State = struct {
        pub const id = "test:profiling-counter";
        pub const Configuration = struct {};

        pub fn init(allocator: std.mem.Allocator, _: @This().Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const selected = .{plugin.configured(State, State.Configuration{})};
    var memory: [128 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try persistence.Store.initForTest(fixed.allocator(), .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 128,
    }, 128);
    const Core = Composition(@TypeOf(selected));
    try std.testing.expectError(error.ProfilingCounterRequired, Core.create(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        store.interface(),
        .{ .memory_bytes = 64 * 1024, .tick_bytes = 128 },
        null,
    ));
}

test "composition rejects a plugin instance outside its generation allocation" {
    const Foreign = struct {
        pub const id = "test:foreign-instance";
        pub const Configuration = struct {};

        pub var instance: @This() = .{};

        pub fn init(_: std.mem.Allocator, _: @This().Configuration) !*@This() {
            return &instance;
        }
    };
    const selected = .{plugin.configured(Foreign, Foreign.Configuration{})};
    var memory: [128 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try persistence.Store.initForTest(fixed.allocator(), .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 128,
    }, 128);
    const Core = Composition(@TypeOf(selected));
    const core = try Core.create(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        store.interface(),
        .{ .memory_bytes = 64 * 1024, .tick_bytes = 128, .profiling = false },
        null,
    );
    try std.testing.expectError(error.PluginInitializationOutsideGeneration, core.initialize(selected, .{ .meta = .{} }));
    try std.testing.expectEqual(runtime.Outcome.ok, core.beginClose(0));
    try std.testing.expectEqual(runtime.Progress.complete, core.closeProgress());
}

test "failed composition retains worker memory until asynchronous close completes" {
    const Worker = struct {
        pub const id = "test:startup-worker";
        pub const Configuration = struct {};
        stop: std.Io.Event = .unset,
        thread: std.Thread,
        done: ?lifecycle.Closing.Token = null,
        value: u64 = 0x12345678,

        pub fn init(allocator: std.mem.Allocator, _: @This().Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .thread = undefined };
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            return self;
        }

        fn run(self: *@This()) void {
            self.stop.waitUncancelable(std.testing.io);
            std.debug.assert(self.value == 0x12345678);
            self.value = 42;
            if (self.done) |token| token.finish();
        }

        pub fn close(self: *@This(), closing: *lifecycle.Closing) void {
            self.done = closing.begin();
            self.stop.set(std.testing.io);
        }
    };
    const Failed = struct {
        pub const id = "test:startup-failure";
        pub const Configuration = struct {};
        pub fn init(_: std.mem.Allocator, _: @This().Configuration) !*@This() {
            return error.InjectedStartupFailure;
        }
    };
    const selected = plugin.compose(.{
        plugin.configured(Worker, Worker.Configuration{}),
        plugin.configured(Failed, Failed.Configuration{}),
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const store = try persistence.Store.initForTest(arena.allocator(), .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 32,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 256,
    }, 256);
    const core = try Composition(@TypeOf(selected)).create(arena.allocator(), std.testing.io, store.interface(), .{ .memory_bytes = 64 * 1024, .tick_bytes = 0, .profiling = false }, null);
    try std.testing.expectError(error.InjectedStartupFailure, core.initialize(selected, .{ .meta = .{} }));
    const worker = core.get(Worker);
    defer {
        worker.stop.set(std.testing.io);
        worker.thread.join();
    }
    try std.testing.expectEqual(@as(usize, 1), core.instances.initialized);
    try std.testing.expect(!core.generation.sealed);
    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + std.time.ns_per_s;
    try std.testing.expectEqual(runtime.Outcome.ok, core.beginClose(deadline));
    while (core.closeProgress() != .complete) {
        if (std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds >= deadline) return error.TestTimeout;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u64, 42), worker.value);
    try std.testing.expectEqual(@as(usize, 0), store.test_storage_len);
}
