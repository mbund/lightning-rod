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

pub const Configuration = struct {
    maximum_bytes: usize,
    tick_bytes: usize,
    profiling: bool = true,

    pub fn validate(self: Configuration) !void {
        if (self.maximum_bytes == 0 or self.tick_bytes == 0 or self.tick_bytes >= self.maximum_bytes)
            return error.InvalidCapacity;
    }
};

pub const Memory = struct {
    maximum_bytes: usize,
    generation_reserved_bytes: usize,
    generation_used_bytes: usize,
    tick_reserved_bytes: usize,

    pub fn reservedBytes(self: Memory) usize {
        return self.generation_used_bytes + self.tick_reserved_bytes;
    }

    pub fn committedBytes(self: Memory) usize {
        return self.maximum_bytes;
    }

    pub fn generationHeadroomBytes(self: Memory) usize {
        return self.generation_reserved_bytes - self.generation_used_bytes;
    }

    pub fn headroomBytes(self: Memory) usize {
        return self.maximum_bytes - self.reservedBytes();
    }
};

pub fn Composition(comptime Selections: type) type {
    plugin.validate(Selections);
    const plugin_count = plugin.selectedCount(Selections);
    const trace_count = plugin.traceCount(Selections);
    const closing_token_count = plugin.closeTokenCount(Selections);

    return struct {
        const Self = @This();

        instances: plugin_runtime.Instances(Selections),
        storage: []u8,
        fixed_overhead_bytes: usize,
        generation: generation_allocator.Allocator,
        temporary: *tick_arena.Arena,
        profiler: plugin_profiler.Profiler,
        persistence: persistence.Interface,
        checkpoint_writer: lifecycle.Checkpoint.Writer,
        closing_storage: []std.atomic.Value(u8),
        closing: lifecycle.Closing = undefined,
        closing_started: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            selections: Selections,
            persistence_interface: persistence.Interface,
            configuration: Configuration,
            counter: ?plugin_profiler.Counter,
            environment: anytype,
        ) !*Self {
            try configuration.validate();
            const storage = try preallocated.alloc(u8, allocator, configuration.maximum_bytes);
            errdefer allocator.free(storage);
            @memset(storage, 0);
            const generation_end = configuration.maximum_bytes - configuration.tick_bytes;
            var bootstrap = std.heap.FixedBufferAllocator.init(storage[0..generation_end]);
            const bootstrap_allocator = bootstrap.allocator();
            const self = bootstrap_allocator.create(Self) catch
                return error.ConfiguredMemoryMaximumExceeded;
            var measurements: plugin_profiler.Profiler = .{};
            measurements.allocate(bootstrap_allocator, plugin_count, trace_count) catch
                return error.ConfiguredMemoryMaximumExceeded;
            const closing_storage = bootstrap_allocator.alloc(std.atomic.Value(u8), @max(closing_token_count, 1)) catch
                return error.ConfiguredMemoryMaximumExceeded;
            const temporary = tick_arena.Arena.createIn(
                bootstrap_allocator,
                storage[generation_end..],
            ) catch return error.ConfiguredMemoryMaximumExceeded;
            const fixed_overhead_bytes = bootstrap.end_index;
            if (fixed_overhead_bytes >= generation_end)
                return error.ConfiguredMemoryMaximumExceeded;
            self.* = .{
                .instances = undefined,
                .storage = storage,
                .fixed_overhead_bytes = fixed_overhead_bytes,
                .generation = generation_allocator.Allocator.init(storage[fixed_overhead_bytes..generation_end]),
                .temporary = temporary,
                .profiler = measurements,
                .persistence = persistence_interface,
                .checkpoint_writer = lifecycle.Checkpoint.Writer.init(persistence_interface),
                .closing_storage = closing_storage,
            };
            if (counter) |value| self.profiler.setCounter(value);
            self.profiler.setEnabled(configuration.profiling) catch
                return error.ProfilingCounterRequired;
            self.generation.trackPlugins(self.profiler.generationMemory());
            self.instances = plugin_runtime.initialize(
                Selections,
                selections,
                &self.generation,
                &self.profiler,
                environment,
            ) catch |err| {
                if (@as(anyerror, err) == error.OutOfMemory)
                    return error.ConfiguredMemoryMaximumExceeded;
                return err;
            };
            self.closing = lifecycle.Closing.init(0, io, self.closing_storage);
            return self;
        }

        pub fn finishInitialization(self: *Self) void {
            std.debug.assert(!self.generation.sealed);
            self.generation.seal();
            std.debug.assert(self.memory().reservedBytes() <= self.storage.len);
        }

        pub fn tick(self: *Self) runtime.Outcome {
            std.debug.assert(self.generation.sealed);
            const temporary = self.temporary.begin();
            defer self.temporary.finish();
            plugin_runtime.tick(Selections, &self.instances, temporary, &self.profiler);
            return .ok;
        }

        pub fn captureCheckpoint(self: *Self) runtime.CheckpointCapture {
            std.debug.assert(self.generation.sealed);
            switch (self.persistence.checkpointProgress()) {
                .ready => {},
                .pending, .backpressured => return .busy,
                .failed, .missing, .too_small => return .failed,
            }
            plugin_runtime.checkpoint(
                &self.instances,
                &self.checkpoint_writer,
                &self.profiler,
            ) catch return .failed;
            return switch (self.persistence.beginCheckpoint()) {
                .ready, .pending => .captured,
                .backpressured => .busy,
                .failed, .missing, .too_small => .failed,
            };
        }

        pub fn checkpointProgress(self: *const Self) runtime.Progress {
            return switch (self.persistence.checkpointProgress()) {
                .ready => .complete,
                .pending, .backpressured => .pending,
                .failed, .missing, .too_small => .failed,
            };
        }

        pub fn beginClose(self: *Self, deadline_ns: i128) runtime.Outcome {
            std.debug.assert(self.generation.sealed);
            if (self.closing_started) return .ok;
            const wake = self.closing.wake;
            self.closing = lifecycle.Closing.init(deadline_ns, self.closing.io, self.closing_storage);
            self.closing.preserveWake(wake);
            plugin_runtime.close(&self.instances, &self.closing, &self.profiler);
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
            return .{
                .maximum_bytes = self.storage.len,
                .generation_reserved_bytes = self.storage.len - self.temporary.bytes.len,
                .generation_used_bytes = self.fixed_overhead_bytes + self.generation.used(),
                .tick_reserved_bytes = self.temporary.bytes.len,
            };
        }
    };
}

test "composition owns bounded tick, checkpoint, and close lifecycle" {
    const State = struct {
        pub const id = "test:state";
        pub const Configuration = struct {};
        value: u8 = 0,

        pub fn init(allocator: std.mem.Allocator, _: @This().Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }

        pub fn tick(self: *@This()) void {
            self.value += 1;
        }

        pub fn checkpoint(self: *@This(), writer: *lifecycle.Checkpoint.NamespaceWriter) !void {
            try writer.put("value", &.{self.value});
        }
    };
    const selected = .{plugin.configured(State, State.Configuration{})};
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
    }, 1024);
    const Core = Composition(@TypeOf(selected));
    const core = try Core.init(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        selected,
        store.interface(),
        .{ .maximum_bytes = 64 * 1024, .tick_bytes = 128, .profiling = false },
        null,
        .{ .meta = .{} },
    );
    core.finishInitialization();
    try std.testing.expectEqual(runtime.Outcome.ok, core.tick());
    const memory_report = core.memory();
    try std.testing.expectEqual(@as(usize, 64 * 1024), memory_report.maximum_bytes);
    try std.testing.expect(memory_report.reservedBytes() <= memory_report.maximum_bytes);
    try std.testing.expectEqual(
        core.fixed_overhead_bytes + core.generation.used() + core.temporary.bytes.len,
        memory_report.reservedBytes(),
    );
    try std.testing.expectEqual(runtime.CheckpointCapture.captured, core.captureCheckpoint());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(runtime.Progress.complete, core.checkpointProgress());
    try std.testing.expectEqual(runtime.Outcome.ok, core.beginClose(100));
    try std.testing.expectEqual(runtime.Progress.complete, core.closeProgress());
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
    }, 128);
    const Core = Composition(@TypeOf(selected));
    try std.testing.expectError(error.ConfiguredMemoryMaximumExceeded, Core.init(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        selected,
        store.interface(),
        .{ .maximum_bytes = 256, .tick_bytes = 128, .profiling = true },
        null,
        .{ .meta = .{} },
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
    }, 128);
    const Core = Composition(@TypeOf(selected));
    try std.testing.expectError(error.ProfilingCounterRequired, Core.init(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        selected,
        store.interface(),
        .{ .maximum_bytes = 64 * 1024, .tick_bytes = 128 },
        null,
        .{ .meta = .{} },
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
    }, 128);
    const Core = Composition(@TypeOf(selected));
    try std.testing.expectError(error.PluginInitializationOutsideGeneration, Core.init(
        fixed.allocator(),
        std.Io.Threaded.global_single_threaded.io(),
        selected,
        store.interface(),
        .{ .maximum_bytes = 64 * 1024, .tick_bytes = 128, .profiling = false },
        null,
        .{ .meta = .{} },
    ));
}
