const std = @import("std");
const registry = @import("registry_data");
const block_store = @import("blocks.zig");
const clock_store = @import("clock.zig");
const generator_api = @import("generator_api.zig");
const geometry = @import("geometry.zig");
const identity = @import("identity.zig");
const preallocated = @import("preallocated");
const terrain = @import("../terrain.zig");
const world_store = @import("worlds.zig");

pub const Flat = struct {
    pub const id = "minecraft:flat";
    pub const Configuration = struct {
        surface_y: i16 = 64,
        surface_state: i32 = registry.block_grass_block_default_state,
        underground_state: i32 = registry.block_stone_default_state,
    };
    pub const default_configuration: Configuration = .{};

    surface_y: i16 = 64,
    surface_state: i32 = registry.block_grass_block_default_state,
    underground_state: i32 = registry.block_stone_default_state,
    storage: [terrain.chunk_storage_capacity]u8 = undefined,

    pub fn configured(configuration: Configuration) Flat {
        return .{
            .surface_y = configuration.surface_y,
            .surface_state = configuration.surface_state,
            .underground_state = configuration.underground_state,
        };
    }

    pub fn initialize(_: *Flat, _: std.mem.Allocator) !void {}

    pub fn generate(
        self: *Flat,
        seed: u64,
        chunk: geometry.ChunkPos,
    ) !terrain.ChunkShape {
        _ = seed;
        return terrain.buildFlatChunkShape(
            &self.storage,
            chunk.x,
            chunk.z,
            self.surface_y,
            self.surface_state,
            self.underground_state,
        );
    }
};

pub const Void = struct {
    pub const id = "minecraft:void";
    pub const Configuration = struct {};
    pub const default_configuration: Configuration = .{};

    storage: [terrain.chunk_storage_capacity]u8 = undefined,

    pub fn configured(_: Configuration) Void {
        return .{};
    }

    pub fn initialize(_: *Void, _: std.mem.Allocator) !void {}

    pub fn generate(
        self: *Void,
        seed: u64,
        chunk: geometry.ChunkPos,
    ) !terrain.ChunkShape {
        _ = seed;
        return terrain.buildVoidChunkShape(&self.storage, chunk.x, chunk.z);
    }
};

pub fn Registry(comptime configured: anytype) type {
    comptime validate(configured);
    const Algorithms = algorithmStorage(@TypeOf(configured));
    const ConfigurationTuple = configurationStorage(Algorithms);
    const defaults = configurationDefaults(ConfigurationTuple, configured);
    return struct {
        const Self = @This();
        pub const id = "lightning_rod:world_generation";
        pub const Dependencies = struct {
            worlds: *world_store.Worlds,
            blocks: *block_store.Blocks,
            clock: *clock_store.Clock,
        };
        pub const Configuration = struct {
            algorithms: ConfigurationTuple = defaults,
            maximum_requests: usize = 4096,
            tick_budget_ns: u64 = 10 * std.time.ns_per_ms,
        };
        pub const default_configuration: Configuration = .{};

        deps: Dependencies,
        algorithms: Algorithms,
        transient_storage: []u8,
        transient_allocator: std.heap.FixedBufferAllocator,
        active_transient: ?u16 = null,
        requests: []geometry.WorldChunk,
        priorities: []generator_api.Priority,
        render_order: []u64,
        request_lookup: []u16,
        request_count: usize = 0,
        active_request: ?u16 = null,
        next_render_order: u64 = 0,
        generation_calls: u64 = 0,
        generation_nanoseconds: u64 = 0,
        generation_maximum_nanoseconds: u64 = 0,
        generation_materialization_nanoseconds: u64 = 0,
        generated_chunks: u64 = 0,
        tick_budget_ns: u64,

        pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Self {
            if (configuration.maximum_requests == 0 or
                configuration.maximum_requests >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(configuration.maximum_requests))
                return error.InvalidGenerationRequestCapacity;
            if (configuration.tick_budget_ns == 0) return error.InvalidGenerationTickBudget;
            const self = try preallocated.create(Self, allocator);
            const transient_bytes = transientWorkspaceBytes(Algorithms);
            const transient_storage = try preallocated.alloc(u8, allocator, transient_bytes);
            self.* = .{
                .deps = deps,
                .algorithms = configureAlgorithms(Algorithms, configuration.algorithms),
                .transient_storage = transient_storage,
                .transient_allocator = std.heap.FixedBufferAllocator.init(transient_storage),
                .requests = try preallocated.alloc(geometry.WorldChunk, allocator, configuration.maximum_requests),
                .priorities = try preallocated.alloc(generator_api.Priority, allocator, configuration.maximum_requests),
                .render_order = try preallocated.alloc(u64, allocator, configuration.maximum_requests),
                .request_lookup = try preallocated.alloc(u16, allocator, configuration.maximum_requests * 2),
                .tick_budget_ns = configuration.tick_budget_ns,
            };
            @memset(self.request_lookup, std.math.maxInt(u16));
            inline for (&self.algorithms) |*algorithm|
                if (!isTransient(@TypeOf(algorithm.*))) try algorithm.initialize(allocator);
            deps.blocks.bindGenerator(.{
                .context = self,
                .generate_fn = dispatch,
                .request_fn = request,
                .pending_fn = pending,
                .capacity_fn = capacity,
                .metrics_fn = metrics,
            });
            if (deps.worlds.active().len != 0) {
                const description = deps.worlds.get(deps.worlds.active()[0]).?;
                inline for (&self.algorithms, 0..) |*algorithm, index| {
                    if (@intFromEnum(description.generator) == index) {
                        try self.activate(index, algorithm);
                        if (comptime @hasDecl(@TypeOf(algorithm.*), "prepare"))
                            try algorithm.prepare(description.seed);
                    }
                }
            }
            return self;
        }

        pub fn tick(self: *Self, _: std.mem.Allocator) void {
            const tick_started = pluginElapsed() orelse 0;
            while (self.request_count != 0 and self.deps.blocks.hasMaterializationCapacity()) {
                if (self.active_request == null) {
                    const next = streamingRequestIndex(
                        self.priorities,
                        self.render_order,
                        self.request_count,
                    );
                    const candidate = self.requests[next];
                    if (self.deps.blocks.materializedChunk(candidate.world, candidate.pos) != null) {
                        self.removeRequest(next);
                        continue;
                    }
                    self.active_request = @intCast(next);
                }
                const selected = self.active_request.?;
                const request_value = self.requests[selected];
                const stage_name = self.dispatchStageName(request_value.world);
                const started = pluginElapsed();
                const shape = dispatchStep(self, request_value.world, request_value.pos) catch |err|
                    std.debug.panic("failed to generate terrain chunk {d}, {d}: {s}", .{ request_value.pos.x, request_value.pos.z, @errorName(err) });
                self.generation_calls +%= 1;
                if (started) |start| {
                    if (pluginElapsed()) |finish| {
                        const elapsed = finish -| start;
                        self.generation_nanoseconds +%= elapsed;
                        self.generation_maximum_nanoseconds = @max(self.generation_maximum_nanoseconds, elapsed);
                        if (elapsed > 40 * std.time.ns_per_ms)
                            std.log.err("event=worldgen_step_deadline_exceeded stage={s} chunk={d},{d} elapsed_us={d}", .{
                                stage_name,
                                request_value.pos.x,
                                request_value.pos.z,
                                @divTrunc(elapsed, std.time.ns_per_us),
                            });
                    }
                }
                if (shape == null) {
                    const elapsed = pluginElapsed() orelse break;
                    if (elapsed -| tick_started >= self.tick_budget_ns) break;
                    continue;
                }
                const emitted = geometry.ChunkPos{ .x = shape.?.chunk_x, .z = shape.?.chunk_z };
                const emitted_index = self.findRequest(request_value.world, emitted) orelse {
                    const elapsed = pluginElapsed() orelse break;
                    if (elapsed -| tick_started >= self.tick_budget_ns) break;
                    continue;
                };
                if (self.deps.blocks.materializedChunk(request_value.world, emitted) != null) {
                    self.removeRequest(emitted_index);
                    const elapsed = pluginElapsed() orelse break;
                    if (elapsed -| tick_started >= self.tick_budget_ns) break;
                    continue;
                }
                const materialization_started = pluginElapsed();
                _ = self.deps.blocks.installMaterialization(request_value.world, shape.?, self.deps.clock.tick, .generated) catch |err|
                    std.debug.panic("failed to install generated terrain chunk {d}, {d}: {s}", .{ shape.?.chunk_x, shape.?.chunk_z, @errorName(err) });
                if (materialization_started) |start| {
                    if (pluginElapsed()) |finish|
                        self.generation_materialization_nanoseconds +%= finish -| start;
                }
                self.generated_chunks +%= 1;
                self.removeRequest(emitted_index);
                const elapsed = pluginElapsed() orelse break;
                if (elapsed -| tick_started >= self.tick_budget_ns) break;
            }
        }

        fn removeRequest(self: *Self, index: usize) void {
            std.debug.assert(index < self.request_count);
            const remaining = self.request_count - 1;
            std.mem.copyForwards(geometry.WorldChunk, self.requests[index..remaining], self.requests[index + 1 .. self.request_count]);
            std.mem.copyForwards(generator_api.Priority, self.priorities[index..remaining], self.priorities[index + 1 .. self.request_count]);
            std.mem.copyForwards(u64, self.render_order[index..remaining], self.render_order[index + 1 .. self.request_count]);
            self.request_count = remaining;
            if (self.active_request) |active| {
                if (active == index)
                    self.active_request = null
                else if (active > index)
                    self.active_request = active - 1;
            }
            self.rebuildRequestLookup();
        }

        fn rebuildRequestLookup(self: *Self) void {
            @memset(self.request_lookup, std.math.maxInt(u16));
            for (self.requests[0..self.request_count], 0..) |queued, queued_index| {
                var probe = requestHash(queued.world, queued.pos);
                while (self.request_lookup[probe & (self.request_lookup.len - 1)] != std.math.maxInt(u16)) probe += 1;
                self.request_lookup[probe & (self.request_lookup.len - 1)] = @intCast(queued_index);
            }
        }

        fn findRequest(self: *const Self, world: identity.Handle, chunk: geometry.ChunkPos) ?usize {
            var probe = requestHash(world, chunk);
            for (0..self.request_lookup.len) |_| {
                const encoded = self.request_lookup[probe & (self.request_lookup.len - 1)];
                if (encoded == std.math.maxInt(u16)) return null;
                const queued = self.requests[encoded];
                if (queued.world.eql(world) and geometry.sameChunk(queued.pos, chunk)) return encoded;
                probe += 1;
            }
            return null;
        }

        fn request(context: *anyopaque, world: identity.Handle, chunk: geometry.ChunkPos, priority: generator_api.Priority) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.deps.blocks.materializedChunk(world, chunk) != null) return true;
            var probe = requestHash(world, chunk);
            for (0..self.request_lookup.len) |_| {
                const lookup_index = probe & (self.request_lookup.len - 1);
                const encoded = self.request_lookup[lookup_index];
                if (encoded == std.math.maxInt(u16)) {
                    if (self.request_count == self.requests.len) return false;
                    const index = self.request_count;
                    self.request_count += 1;
                    self.requests[index] = .{ .world = world, .pos = chunk };
                    self.priorities[index] = priority;
                    self.render_order[index] = if (priority == .streaming) self.assignRenderOrder() else 0;
                    self.request_lookup[lookup_index] = @intCast(index);
                    return true;
                }
                const queued = self.requests[encoded];
                if (queued.world.eql(world) and geometry.sameChunk(queued.pos, chunk)) {
                    if (priority == .streaming and self.priorities[encoded] != .streaming) {
                        self.priorities[encoded] = .streaming;
                        self.render_order[encoded] = self.assignRenderOrder();
                    }
                    return true;
                }
                probe += 1;
            }
            return false;
        }

        fn assignRenderOrder(self: *Self) u64 {
            std.debug.assert(self.next_render_order != std.math.maxInt(u64));
            const order = self.next_render_order;
            self.next_render_order += 1;
            return order;
        }

        fn pending(context: *const anyopaque) usize {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.request_count;
        }

        fn capacity(context: *const anyopaque) usize {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.requests.len;
        }

        fn metrics(context: *const anyopaque) generator_api.Metrics {
            const self: *const Self = @ptrCast(@alignCast(context));
            return .{
                .calls = self.generation_calls,
                .nanoseconds = self.generation_nanoseconds,
                .maximum_nanoseconds = self.generation_maximum_nanoseconds,
                .emitted = self.generated_chunks,
                .installed = self.generated_chunks,
                .materialization_nanoseconds = self.generation_materialization_nanoseconds,
            };
        }

        pub fn generatorId(comptime Algorithm: type) identity.GeneratorId {
            return @enumFromInt(algorithmIndex(@TypeOf(configured), Algorithm));
        }

        pub fn stableId(generator: identity.GeneratorId) ?[]const u8 {
            inline for (configured, 0..) |algorithm, index|
                if (@intFromEnum(generator) == index) return @TypeOf(algorithm).id;
            return null;
        }

        fn dispatch(
            context: *anyopaque,
            world: identity.Handle,
            chunk: geometry.ChunkPos,
        ) anyerror!terrain.ChunkShape {
            const self: *Self = @ptrCast(@alignCast(context));
            const description = self.deps.worlds.get(world) orelse
                return error.StaleWorldHandle;
            inline for (&self.algorithms, 0..) |*algorithm, index| {
                if (@intFromEnum(description.generator) == index) {
                    try self.activate(index, algorithm);
                    return algorithm.generate(description.seed, chunk);
                }
            }
            return error.UnknownWorldGenerator;
        }

        fn dispatchStep(
            self: *Self,
            world: identity.Handle,
            chunk: geometry.ChunkPos,
        ) anyerror!?terrain.ChunkShape {
            const description = self.deps.worlds.get(world) orelse
                return error.StaleWorldHandle;
            inline for (&self.algorithms, 0..) |*algorithm, index| {
                if (@intFromEnum(description.generator) == index) {
                    try self.activate(index, algorithm);
                    if (comptime @hasDecl(@TypeOf(algorithm.*), "step"))
                        return algorithm.step(description.seed, chunk);
                    return try algorithm.generate(description.seed, chunk);
                }
            }
            return error.UnknownWorldGenerator;
        }

        fn dispatchStageName(self: *const Self, world: identity.Handle) []const u8 {
            const description = self.deps.worlds.getConst(world) orelse return "unknown";
            inline for (&self.algorithms, 0..) |*algorithm, index| {
                if (@intFromEnum(description.generator) == index) {
                    if (comptime @hasDecl(@TypeOf(algorithm.*), "stageName")) return algorithm.stageName();
                    return "generate";
                }
            }
            return "unknown";
        }

        fn activate(self: *Self, comptime index: usize, algorithm: anytype) !void {
            const Algorithm = @TypeOf(algorithm.*);
            if (comptime !isTransient(Algorithm)) {
                self.deactivate();
                return;
            }
            if (self.active_transient == @as(u16, @intCast(index))) return;
            self.deactivate();
            self.transient_allocator.reset();
            try algorithm.initialize(self.transient_allocator.allocator());
            self.active_transient = @intCast(index);
        }

        fn deactivate(self: *Self) void {
            const active = self.active_transient orelse return;
            inline for (&self.algorithms, 0..) |*algorithm, index| {
                const Algorithm = @TypeOf(algorithm.*);
                if (comptime isTransient(Algorithm)) {
                    if (active == index) algorithm.deinitialize();
                }
            }
            self.active_transient = null;
        }
    };
}

fn streamingRequestIndex(priorities: []const generator_api.Priority, render_order: []const u64, count: usize) usize {
    std.debug.assert(count != 0);
    var next: usize = 0;
    var found_streaming = false;
    for (priorities[0..count], 0..) |priority, index| {
        if (priority != .streaming) continue;
        if (!found_streaming or render_order[index] < render_order[next]) {
            next = index;
            found_streaming = true;
        }
    }
    return next;
}

const BatchTestGenerator = struct {
    pub const id = "test:batch";

    storage: [3][terrain.chunk_storage_capacity]u8 = undefined,
    active: ?geometry.ChunkPos = null,
    emitted: u2 = 0,

    pub fn initialize(_: *BatchTestGenerator, _: std.mem.Allocator) !void {}

    pub fn generate(self: *BatchTestGenerator, _: u64, chunk: geometry.ChunkPos) !terrain.ChunkShape {
        return terrain.buildFlatChunkShape(
            &self.storage[0],
            chunk.x,
            chunk.z,
            64,
            registry.block_grass_block_default_state,
            registry.block_stone_default_state,
        );
    }

    pub fn step(self: *BatchTestGenerator, _: u64, chunk: geometry.ChunkPos) !?terrain.ChunkShape {
        if (self.active) |active|
            std.debug.assert(geometry.sameChunk(active, chunk))
        else {
            self.active = chunk;
            self.emitted = 0;
        }
        std.debug.assert(self.emitted < 3);
        const output = switch (self.emitted) {
            0 => geometry.ChunkPos{ .x = chunk.x + 1, .z = chunk.z },
            1 => geometry.ChunkPos{ .x = chunk.x + 2, .z = chunk.z },
            2 => chunk,
            else => unreachable,
        };
        const storage_index: usize = self.emitted;
        self.emitted += 1;
        if (self.emitted == 3) self.active = null;
        return try terrain.buildFlatChunkShape(
            &self.storage[storage_index],
            output.x,
            output.z,
            64,
            registry.block_grass_block_default_state,
            registry.block_stone_default_state,
        );
    }
};

test "streaming promotion follows render admission over earlier projections" {
    const TestRegistry = Registry(.{Flat{}});
    const initial = [_]world_store.Description{.{
        .key = .{ .value = 1 },
        .name = "test:initial",
        .dimension = .{ .index = 0 },
        .generator = TestRegistry.generatorId(Flat),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const worlds = try world_store.Worlds.init(allocator, .{ .initial = &initial, .maximum_worlds = 2 });
    const blocks = try block_store.Blocks.init(allocator, .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 4,
        .maximum_block_mutations = 4,
    });
    const clock = try clock_store.Clock.init(allocator, .{});
    const value = try TestRegistry.init(allocator, .{ .worlds = worlds, .blocks = blocks, .clock = clock }, .{
        .maximum_requests = 8,
    });
    const world = worlds.active()[0];
    const projection = geometry.ChunkPos{ .x = 0, .z = -5 };
    const center = geometry.ChunkPos{ .x = 0, .z = 0 };
    const east = geometry.ChunkPos{ .x = 1, .z = 0 };
    const service = blocks.generator.?;

    // Simulation queued the projection before ChunkStreaming became presentation-ready.
    // Render then admits its center and east requests before promoting the old projection.
    try std.testing.expect(service.request(world, projection, .simulation));
    try std.testing.expect(service.request(world, center, .simulation));
    try std.testing.expect(service.request(world, east, .simulation));
    try std.testing.expect(service.request(world, center, .streaming));
    try std.testing.expect(service.request(world, east, .streaming));
    try std.testing.expect(service.request(world, projection, .streaming));
    try std.testing.expect(service.request(world, center, .streaming));

    try std.testing.expectEqual(@as(usize, 3), value.request_count);
    try std.testing.expect(geometry.sameChunk(value.requests[0].pos, projection));
    try std.testing.expectEqual(generator_api.Priority.streaming, value.priorities[1]);
    try std.testing.expectEqual(@as(u64, 0), value.render_order[1]);
    try std.testing.expectEqual(@as(u64, 1), value.render_order[2]);
    try std.testing.expectEqual(@as(u64, 2), value.render_order[0]);
    const selected = streamingRequestIndex(value.priorities, value.render_order, value.request_count);
    try std.testing.expect(geometry.sameChunk(value.requests[selected].pos, center));
}

test "batch outputs drain matching requests without installing unsolicited chunks" {
    const TestRegistry = Registry(.{BatchTestGenerator{}});
    const initial = [_]world_store.Description{.{
        .key = .{ .value = 1 },
        .name = "test:initial",
        .dimension = .{ .index = 0 },
        .generator = TestRegistry.generatorId(BatchTestGenerator),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const worlds = try world_store.Worlds.init(allocator, .{ .initial = &initial, .maximum_worlds = 2 });
    const blocks = try block_store.Blocks.init(allocator, .{
        .maximum_transient_chunks = 8,
        .maximum_modified_sections = 4,
        .maximum_block_mutations = 4,
    });
    const clock = try clock_store.Clock.init(allocator, .{});
    const value = try TestRegistry.init(allocator, .{ .worlds = worlds, .blocks = blocks, .clock = clock }, .{
        .maximum_requests = 8,
    });
    const world = worlds.active()[0];
    const requested = geometry.ChunkPos{ .x = 0, .z = 0 };
    const neighbor = geometry.ChunkPos{ .x = 1, .z = 0 };
    const unsolicited = geometry.ChunkPos{ .x = 2, .z = 0 };
    const service = blocks.generator.?;

    try std.testing.expect(service.request(world, neighbor, .simulation));
    try std.testing.expect(service.request(world, requested, .streaming));
    value.tick(allocator); // Drain the earlier queued neighbor before the active request.
    try std.testing.expectEqual(@as(usize, 1), value.request_count);
    try std.testing.expectEqual(@as(?u16, 0), value.active_request);
    try std.testing.expect(blocks.materializedChunk(world, neighbor) != null);
    blocks.markChunkCleanThrough(world, neighbor, blocks.chunkDirtyRevision(world, neighbor));
    try std.testing.expect(blocks.evictChunk(world, neighbor));

    value.tick(allocator); // The provider's local batch emits an unrequested chunk.
    try std.testing.expectEqual(@as(usize, 1), value.request_count);
    try std.testing.expect(blocks.materializedChunk(world, unsolicited) == null);
    value.tick(allocator); // The active request completes after its earlier neighbor was removed.

    try std.testing.expectEqual(@as(usize, 0), value.request_count);
    try std.testing.expect(blocks.materializedChunk(world, requested) != null);
    try std.testing.expect(blocks.materializedChunk(world, neighbor) == null);
    try std.testing.expect(blocks.materializedChunk(world, unsolicited) == null);
    try std.testing.expectEqual(@as(u64, 3), value.generation_calls);
    try std.testing.expectEqual(@as(u64, 2), value.generated_chunks);

    const next_requested = geometry.ChunkPos{ .x = 3, .z = 0 };
    const persisted_neighbor = geometry.ChunkPos{ .x = 4, .z = 0 };
    var persisted_storage: [terrain.chunk_storage_capacity]u8 = undefined;
    const persisted = try terrain.buildVoidChunkShape(&persisted_storage, persisted_neighbor.x, persisted_neighbor.z);
    try std.testing.expect(service.request(world, next_requested, .streaming));
    try std.testing.expect(service.request(world, persisted_neighbor, .streaming));
    _ = try blocks.installMaterialization(world, persisted, clock.tick, .persisted);
    value.tick(allocator); // A late persisted neighbor drains its request without being overwritten.
    value.tick(allocator); // The next local output is still unrequested.
    value.tick(allocator); // The active request completes.

    try std.testing.expectEqual(@as(usize, 0), value.request_count);
    try std.testing.expect(blocks.materializedChunk(world, next_requested) != null);
    try std.testing.expect(!(blocks.materializedChunk(world, persisted_neighbor).?.dirty));
    try std.testing.expectEqual(@as(u64, 6), value.generation_calls);
    try std.testing.expectEqual(@as(u64, 3), value.generated_chunks);
}

fn requestHash(world: identity.Handle, chunk: geometry.ChunkPos) usize {
    var value = @as(u64, @bitCast(@as(i64, chunk.x))) *% 0x9e3779b185ebca87;
    value ^= @as(u64, @bitCast(@as(i64, chunk.z))) *% 0xc2b2ae3d27d4eb4f;
    value ^= (@as(u64, world.index) << 32) | world.generation;
    return @truncate(value ^ (value >> 32));
}

fn pluginElapsed() ?u64 {
    return @import("../plugin_profiler.zig").tickElapsedNanoseconds();
}

fn isTransient(comptime Algorithm: type) bool {
    return @hasDecl(Algorithm, "transient_workspace_bytes");
}

fn transientWorkspaceBytes(comptime Algorithms: type) usize {
    var bytes: usize = 0;
    inline for (@typeInfo(Algorithms).@"struct".fields) |field| {
        if (comptime isTransient(field.type)) bytes = @max(bytes, field.type.transient_workspace_bytes);
    }
    return bytes;
}

fn algorithmStorage(comptime Configured: type) type {
    const fields = @typeInfo(Configured).@"struct".fields;
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| types[index] = field.type;
    return std.meta.Tuple(&types);
}

fn configurationStorage(comptime Algorithms: type) type {
    const fields = @typeInfo(Algorithms).@"struct".fields;
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index|
        types[index] = if (@hasDecl(field.type, "Configuration")) field.type.Configuration else struct {};
    return std.meta.Tuple(&types);
}

fn configurationDefaults(comptime Configuration: type, comptime configured: anytype) Configuration {
    var result: Configuration = undefined;
    inline for (@typeInfo(Configuration).@"struct".fields, 0..) |field, index| {
        const Algorithm = @TypeOf(configured[index]);
        @field(result, field.name) = if (@hasDecl(Algorithm, "default_configuration"))
            Algorithm.default_configuration
        else
            .{};
    }
    return result;
}

fn configureAlgorithms(comptime Algorithms: type, configuration: anytype) Algorithms {
    var result: Algorithms = undefined;
    inline for (@typeInfo(Algorithms).@"struct".fields, 0..) |field, index|
        @field(result, field.name) = if (@hasDecl(field.type, "configured"))
            field.type.configured(configuration[index])
        else
            .{};
    return result;
}

fn algorithmIndex(comptime Algorithms: type, comptime Algorithm: type) usize {
    inline for (@typeInfo(Algorithms).@"struct".fields, 0..) |field, index|
        if (field.type == Algorithm) return index;
    @compileError("world generator is absent from the configured registry: " ++ @typeName(Algorithm));
}

fn validate(comptime configured: anytype) void {
    if (configured.len == 0) @compileError("a world-generation registry cannot be empty");
    if (configured.len > std.math.maxInt(u16)) @compileError("too many world generators");
    inline for (configured, 0..) |algorithm, index| {
        const Algorithm = @TypeOf(algorithm);
        if (!@hasDecl(Algorithm, "id") or Algorithm.id.len == 0)
            @compileError("world generator must declare a stable non-empty id");
        if (!@hasDecl(Algorithm, "generate"))
            @compileError(Algorithm.id ++ " must implement generate");
        if (!@hasDecl(Algorithm, "initialize"))
            @compileError(Algorithm.id ++ " must implement initialize");
        inline for (0..index) |previous_index|
            if (std.mem.eql(u8, Algorithm.id, @TypeOf(configured[previous_index]).id))
                @compileError("duplicate world generator id: " ++ Algorithm.id);
    }
}
