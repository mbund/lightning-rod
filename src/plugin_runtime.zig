const std = @import("std");
const generation_allocator = @import("generation_allocator.zig");
const lifecycle = @import("plugin_lifecycle.zig");
const profiler = @import("plugin_profiler.zig");
const persistence = @import("persistence.zig");
const selection = @import("plugin.zig");

pub fn Instances(comptime Selections: type) type {
    const count = selection.selectedCount(Selections);
    return struct {
        const Self = @This();
        pub const selections = Selections;

        pointers: [count]*anyopaque,

        inline fn at(self: *const Self, comptime Plugin: type, index: usize) *Plugin {
            return @ptrCast(@alignCast(self.pointers[index]));
        }
    };
}

pub fn initialize(
    comptime Selections: type,
    selections: Selections,
    generation: *generation_allocator.Allocator,
    measurements: *profiler.Profiler,
    environment: anytype,
) !Instances(Selections) {
    var instances: Instances(Selections) = undefined;
    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));
        instances.pointers[index] = try initializeOne(Selections, Plugin, index, &instances, selections[index].configuration, generation, measurements, &environment);
    }
    measurements.setGenerationMemory(generation.plugin_bytes);
    return instances;
}

fn initializeOne(
    comptime Selections: type,
    comptime Plugin: type,
    comptime index: usize,
    instances: *const Instances(Selections),
    configuration: Plugin.Configuration,
    generation: *generation_allocator.Allocator,
    measurements: *profiler.Profiler,
    environment: anytype,
) !*Plugin {
    generation.beginPlugin(index);
    defer generation.endPlugin();
    measurements.setPluginName(index, Plugin.id);
    registerTraces(Selections, Plugin, index, measurements);
    const started = measurements.beginInitialization(index);
    defer measurements.endInitialization(index, started);
    const plugin = try callInit(Selections, Plugin, index, instances, generation.allocator(), configuration, environment);
    if (!generation.ownsCurrentPluginAllocation(plugin)) return error.PluginInitializationOutsideGeneration;
    return plugin;
}

fn callInit(
    comptime Selections: type,
    comptime Plugin: type,
    comptime index: usize,
    instances: *const Instances(Selections),
    allocator: std.mem.Allocator,
    configuration: Plugin.Configuration,
    environment: anytype,
) !*Plugin {
    const has_dependencies = @hasDecl(Plugin, "Dependencies");
    const has_meta = @hasDecl(Plugin, "Meta");
    if (comptime has_dependencies and has_meta)
        return @call(.never_inline, Plugin.init, .{ allocator, dependencies(Selections, Plugin, index, instances, environment), configuration, metadata(Plugin, environment) });
    if (comptime has_dependencies)
        return @call(.never_inline, Plugin.init, .{ allocator, dependencies(Selections, Plugin, index, instances, environment), configuration });
    if (comptime has_meta)
        return @call(.never_inline, Plugin.init, .{ allocator, configuration, metadata(Plugin, environment) });
    return @call(.never_inline, Plugin.init, .{ allocator, configuration });
}

pub fn tick(comptime Selections: type, instances: anytype, temporary: std.mem.Allocator, measurements: *profiler.Profiler) void {
    measurements.beginTick();
    defer measurements.finishTick();
    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));
        if (comptime @hasDecl(Plugin, "tick"))
            tickOne(Selections, Plugin, instances.at(Plugin, index), index, temporary);
    }
}

pub fn checkpoint(instances: anytype, writer: *lifecycle.Checkpoint.Writer, measurements: *profiler.Profiler) !void {
    const Selections = @TypeOf(instances.*).selections;
    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));
        if (comptime @hasDecl(Plugin, "checkpoint"))
            try checkpointOne(Plugin, instances.at(Plugin, index), index, writer, measurements);
    }
}

pub fn close(instances: anytype, closing: *lifecycle.Closing, measurements: *profiler.Profiler) void {
    const Selections = @TypeOf(instances.*).selections;
    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));
        if (comptime @hasDecl(Plugin, "close"))
            closeOne(Plugin, instances.at(Plugin, index), index, closing, measurements);
    }
}

pub inline fn get(instances: anytype, comptime Plugin: type) *Plugin {
    const Selections = @TypeOf(instances.*).selections;
    const index = comptime selectedIndex(Selections, Plugin) orelse
        @compileError("plugin is not selected: " ++ Plugin.id);
    return instances.at(Plugin, index);
}

fn dependencies(comptime Selections: type, comptime Plugin: type, comptime current: usize, instances: *const Instances(Selections), environment: anytype) selection.dependenciesType(Plugin) {
    var result: selection.dependenciesType(Plugin) = undefined;
    inline for (@typeInfo(selection.dependenciesType(Plugin)).@"struct".fields) |field|
        @field(result, field.name) = dependency(Selections, Plugin, field.name, field.type, current, instances, environment);
    return result;
}

fn dependency(comptime Selections: type, comptime Requester: type, comptime name: []const u8, comptime T: type, comptime current: usize, instances: *const Instances(Selections), environment: anytype) T {
    if (T == persistence.PluginAccess) {
        if (!@hasField(@TypeOf(environment.*), "persistence"))
            @compileError("a plugin persistence dependency requires application persistence");
        return environment.persistence.plugin(Requester.id);
    }
    const Plugin = dependencyPlugin(T) orelse return environmental(name, T, environment);
    const index = comptime selection.indexOfId(Selections, Plugin.id);
    if (index == null) {
        if (@typeInfo(T) != .optional) @compileError("required plugin dependency is not selected");
        return null;
    }
    if (index.? >= current) @compileError("plugin dependency must occur earlier in composition order");
    if (comptime selection.selectedPlugin(selection.selectedType(Selections, index.?)) != Plugin)
        @compileError("plugin dependency type does not match its selected replacement");
    return instances.at(Plugin, index.?);
}

fn selectedIndex(comptime Selections: type, comptime Plugin: type) ?usize {
    inline for (0..selection.selectedCount(Selections)) |index|
        if (selection.selectedPlugin(selection.selectedType(Selections, index)) == Plugin)
            return index;
    return null;
}

fn dependencyPlugin(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| if (isPlugin(pointer.child)) pointer.child else null,
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .pointer => |pointer| if (isPlugin(pointer.child)) pointer.child else null,
            else => @compileError("optional dependency must be ?*Plugin"),
        },
        else => @compileError("dependency must be *Plugin or ?*Plugin"),
    };
}

fn isPlugin(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "id");
}

fn environmental(comptime name: []const u8, comptime T: type, environment: anytype) T {
    const Environment = @TypeOf(environment.*);
    if (@hasField(Environment, name)) return @field(environment.*, name);
    comptime var match: ?[]const u8 = null;
    inline for (@typeInfo(Environment).@"struct".fields) |field| {
        const matches = field.type == T or
            (@typeInfo(T) == .optional and field.type == @typeInfo(T).optional.child);
        if (!matches) continue;
        if (match != null) @compileError("ambiguous plugin environment dependency: " ++ name);
        match = field.name;
    }
    if (match) |field_name| return @field(environment.*, field_name);
    if (@typeInfo(T) == .optional) return null;
    @compileError("missing required plugin environment dependency: " ++ name);
}

fn metadata(comptime Plugin: type, environment: anytype) Plugin.Meta {
    if (!@hasField(@TypeOf(environment.*), "meta"))
        @compileError("plugins declaring Meta require an application meta value");
    const source = @field(environment.*, "meta");
    var result: Plugin.Meta = undefined;
    inline for (@typeInfo(Plugin.Meta).@"struct".fields) |field| {
        if (!@hasField(@TypeOf(source), field.name)) {
            if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
                continue;
            }
            @compileError("missing required plugin meta field: " ++ field.name);
        }
        const value = @field(source, field.name);
        @field(result, field.name) = value;
    }
    return result;
}

fn callTick(comptime Plugin: type, plugin: *Plugin, temporary: std.mem.Allocator) void {
    const info = @typeInfo(@TypeOf(Plugin.tick)).@"fn";
    if (info.params.len == 1) return @call(.never_inline, Plugin.tick, .{plugin});
    @call(.never_inline, Plugin.tick, .{ plugin, temporary });
}

fn tickOne(comptime Selections: type, comptime Plugin: type, instance: *Plugin, comptime index: usize, temporary: std.mem.Allocator) void {
    const started = profiler.beginPlugin(
        index,
        selection.traceBase(Selections, index),
        selection.pluginTraceCount(Plugin),
    );
    defer profiler.endPlugin(index, started);
    callTick(Plugin, instance, temporary);
}

fn registerTraces(comptime Selections: type, comptime Plugin: type, comptime plugin_index: usize, measurements: *profiler.Profiler) void {
    if (comptime !@hasDecl(Plugin, "Trace")) return;
    const trace_base = selection.traceBase(Selections, plugin_index);
    inline for (@typeInfo(Plugin.Trace).@"enum".fields, 0..) |field, local_index|
        measurements.setTrace(trace_base + local_index, plugin_index, field.name);
}

fn callCheckpoint(comptime Plugin: type, plugin: *Plugin, writer: *lifecycle.Checkpoint.NamespaceWriter) !void {
    try @call(.never_inline, Plugin.checkpoint, .{ plugin, writer });
}

fn checkpointOne(
    comptime Plugin: type,
    instance: *Plugin,
    index: usize,
    writer: *lifecycle.Checkpoint.Writer,
    measurements: *profiler.Profiler,
) !void {
    const started = measurements.beginCheckpoint(index);
    defer measurements.endCheckpoint(index, started);
    var namespaced = try writer.bind(Plugin.id);
    try callCheckpoint(Plugin, instance, &namespaced);
}

fn callClose(comptime Plugin: type, plugin: *Plugin, closing: *lifecycle.Closing) void {
    @call(.never_inline, Plugin.close, .{ plugin, closing });
}

fn closeOne(
    comptime Plugin: type,
    instance: *Plugin,
    index: usize,
    closing: *lifecycle.Closing,
    measurements: *profiler.Profiler,
) void {
    const started = measurements.beginClosing(index);
    defer measurements.endClosing(index, started);
    callClose(Plugin, instance, closing);
}

test "the pipeline ticks in composition order and injects earlier dependencies" {
    const First = struct {
        pub const id = "test:first";
        pub const Configuration = struct {};
        pub const Trace = enum { work };
        value: u8 = 0,
        pub fn init(a: std.mem.Allocator, _: Configuration) !*@This() {
            const self = try a.create(@This());
            self.* = .{};
            return self;
        }
        pub fn tick(self: *@This(), _: std.mem.Allocator) void {
            var trace = profiler.beginTrace(Trace.work);
            defer trace.end();
            self.value += 1;
        }
    };
    const Second = struct {
        pub const id = "test:second";
        pub const Dependencies = struct { first: *First };
        pub const Configuration = struct {};
        observed: u8 = 0,
        pub fn init(a: std.mem.Allocator, deps: Dependencies, _: Configuration) !*@This() {
            const self = try a.create(@This());
            self.* = .{ .observed = deps.first.value };
            return self;
        }
        pub fn tick(self: *@This(), _: std.mem.Allocator) void {
            self.observed += 1;
        }
    };
    const selections = .{ selection.configured(First, First.Configuration{}), selection.configured(Second, Second.Configuration{}) };
    var bytes: [1024]u8 = undefined;
    var generation = generation_allocator.Allocator.init(&bytes);
    var measures: profiler.Profiler = .{};
    var metric_bytes: [32 * 1024]u8 = undefined;
    var metric_storage = std.heap.FixedBufferAllocator.init(&metric_bytes);
    try measures.allocate(metric_storage.allocator(), 2, 1);
    measures.setCounter(.{ .context = &test_counter, .read_fn = readTestCounter });
    try measures.setEnabled(true);
    generation.trackPlugins(measures.generationMemory());
    var instances = try initialize(@TypeOf(selections), selections, &generation, &measures, .{ .meta = .{} });
    var tick_bytes: [32]u8 = undefined;
    var tick_storage = std.heap.FixedBufferAllocator.init(&tick_bytes);
    tick(@TypeOf(selections), &instances, tick_storage.allocator(), &measures);
    try std.testing.expectEqual(@as(u8, 1), get(&instances, First).value);
    try std.testing.expectEqual(@as(u8, 1), get(&instances, Second).observed);
    try std.testing.expect(measures.plugins[0].last_ns > 0);
    try std.testing.expect(measures.plugins[1].last_ns > 0);
    const view = measures.snapshot();
    try std.testing.expectEqual(@as(usize, 1), view.trace_count);
    try std.testing.expectEqualStrings("work", view.traces[0].name());
    try std.testing.expectEqual(@as(usize, 0), view.traces[0].plugin_index);
}

test "close starts every plugin before reporting token completion" {
    const First = struct {
        pub const id = "test:close-first";
        pub const Configuration = struct {};
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, _: Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }

        pub fn close(self: *@This(), closing: *lifecycle.Closing) void {
            self.closed = true;
            const done = closing.begin();
            done.finish();
        }
    };
    const Second = struct {
        pub const id = "test:close-second";
        pub const Configuration = struct {};
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, _: Configuration) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{};
            return self;
        }

        pub fn close(self: *@This(), _: *lifecycle.Closing) void {
            self.closed = true;
        }
    };
    var bytes: [1024]u8 = undefined;
    var generation = generation_allocator.Allocator.init(&bytes);
    var measures: profiler.Profiler = .{};
    var metric_bytes: [32 * 1024]u8 = undefined;
    var metric_storage = std.heap.FixedBufferAllocator.init(&metric_bytes);
    try measures.allocate(metric_storage.allocator(), 2, 0);
    generation.trackPlugins(measures.generationMemory());
    const selections = .{ selection.configured(First, First.Configuration{}), selection.configured(Second, Second.Configuration{}) };
    var instances = try initialize(@TypeOf(selections), selections, &generation, &measures, .{ .meta = .{} });
    var completed: [2]std.atomic.Value(u8) = undefined;
    var closing = lifecycle.Closing.init(1, std.Io.Threaded.global_single_threaded.io(), &completed);
    close(&instances, &closing, &measures);
    try std.testing.expect(get(&instances, First).closed);
    try std.testing.expect(get(&instances, Second).closed);
    try std.testing.expect(closing.complete());
}

test "initialization injects typed environment and projected metadata" {
    const Sessions = struct { value: u8 };
    const Feature = struct {
        pub const id = "test:ambient";
        pub const Configuration = struct {};
        pub const Dependencies = struct { sessions: *Sessions };
        pub const Meta = struct { name: []const u8, optional: ?u16 };
        deps: Dependencies,
        meta: Meta,

        pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration, meta: Meta) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .deps = deps, .meta = meta };
            return self;
        }
    };
    const selected = .{selection.configured(Feature, Feature.Configuration{})};
    var bytes: [1024]u8 = undefined;
    var generation = generation_allocator.Allocator.init(&bytes);
    var measures: profiler.Profiler = .{};
    var metric_bytes: [32 * 1024]u8 = undefined;
    var metric_storage = std.heap.FixedBufferAllocator.init(&metric_bytes);
    try measures.allocate(metric_storage.allocator(), 1, 0);
    generation.trackPlugins(measures.generationMemory());
    var sessions = Sessions{ .value = 7 };
    const instances = try initialize(@TypeOf(selected), selected, &generation, &measures, .{
        .sessions = &sessions,
        .meta = .{ .name = "server", .unrelated = true },
    });
    const feature = get(&instances, Feature);
    try std.testing.expectEqual(@as(u8, 7), feature.deps.sessions.value);
    try std.testing.expectEqualStrings("server", feature.meta.name);
    try std.testing.expectEqual(@as(?u16, null), feature.meta.optional);
}

fn readTestCounter(context: *const anyopaque) u64 {
    const value: *std.atomic.Value(u64) = @ptrCast(@alignCast(@constCast(context)));
    return value.fetchAdd(1, .monotonic);
}

var test_counter: std.atomic.Value(u64) = .init(1);
