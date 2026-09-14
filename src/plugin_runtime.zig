const std = @import("std");

const assert = std.debug.assert;
const selection = @import("plugin.zig");
const memory = @import("memory.zig");
const metrics = @import("metrics.zig");
const lifecycle = @import("plugin_lifecycle.zig");
const storage = @import("storage");
const Work = @import("work.zig").Work;

pub fn Instances(comptime Selections: type) type {
    selection.validate(Selections);
    return struct {
        pub const selections = Selections;
        pointers: [selection.selectedCount(Selections)]*anyopaque = undefined,
        initialized: usize = 0,

        pub fn get(self: *const @This(), comptime Plugin: type) *Plugin {
            const index = comptime selection.indexOfId(Selections, Plugin.id) orelse
                @compileError("plugin is not selected: " ++ Plugin.id);

            if (selection.selectedPlugin(selection.selectedType(Selections, index)) != Plugin)
                @compileError("selected plugin has a different type: " ++ Plugin.id);
            assert(index < self.initialized);
            return @ptrCast(@alignCast(self.pointers[index]));
        }
    };
}

pub fn initialize(instances: anytype, selections: @TypeOf(instances.*).selections, allocator: *memory.Allocator, measurements: *metrics.Metrics, io: std.Io, transaction: storage.Transaction, work: *Work, environment: anytype) !void {
    const Selections = @TypeOf(instances.*).selections;
    assert(instances.initialized == 0);

    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));
        const base = comptime selection.traceBase(Selections, index);
        const count = comptime selection.pluginTraceCount(Plugin);
        measurements.plugins[index].name = Plugin.id;

        if (@hasDecl(Plugin, "Trace")) inline for (@typeInfo(Plugin.Trace).@"enum".fields, 0..) |field, offset| {
            measurements.traces[base + offset].name = field.name;
        };

        allocator.beginPlugin(index);
        defer allocator.endPlugin();
        const timing = measurements.enter(index, base, count);
        defer timing.end();
        var args: std.meta.ArgsTuple(@TypeOf(Plugin.init)) = undefined;

        inline for (@typeInfo(@TypeOf(Plugin.init)).@"fn".params, 0..) |parameter, argument| {
            const T = parameter.type.?;
            args[argument] = if (T == std.mem.Allocator) allocator.allocator() else if (T == std.Io) io else if (T == Plugin.Configuration) selections[index].configuration else if (@hasDecl(Plugin, "Dependencies") and T == Plugin.Dependencies) try dependencies(Plugin.Dependencies, Plugin.id, instances, transaction, work, environment) else if (@hasDecl(Plugin, "Meta") and T == Plugin.Meta) metadata(T, if (@hasField(@TypeOf(environment), "meta")) environment.meta else .{}) else unreachable;
        }

        const instance = try @call(.never_inline, Plugin.init, args);
        if (!allocator.ownsCurrentPluginAllocation(instance)) return error.PluginAllocationInvalid;
        measurements.plugins[index].persistent_bytes = allocator.currentPluginBytes();
        instances.pointers[index] = instance;
        instances.initialized += 1;
    }
}

pub fn tick(instances: anytype, temporary: *std.heap.FixedBufferAllocator, measurements: *metrics.Metrics, io: std.Io, transaction: storage.Transaction) !void {
    const Selections = @TypeOf(instances.*).selections;
    assert(instances.initialized == selection.selectedCount(Selections));

    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));

        if (@hasDecl(Plugin, "tick")) {
            const timing = measurements.enter(index, selection.traceBase(Selections, index), selection.pluginTraceCount(Plugin));
            defer timing.end();
            const before = temporary.end_index;
            var args: std.meta.ArgsTuple(@TypeOf(Plugin.tick)) = undefined;
            args[0] = instances.get(Plugin);

            inline for (@typeInfo(@TypeOf(Plugin.tick)).@"fn".params[1..], 1..) |parameter, argument| {
                args[argument] = if (parameter.type == std.Io) io else if (parameter.type == storage.Namespace) try transaction.namespace(Plugin.id) else temporary.allocator();
            }

            const result = @call(.never_inline, Plugin.tick, args);

            if (@typeInfo(@TypeOf(result)) == .error_union) try result;
            measurements.plugins[index].temporary_bytes = temporary.end_index -| before;
        }
    }
}

pub fn checkpoint(instances: anytype, io: std.Io, transaction: storage.Transaction) !void {
    const Selections = @TypeOf(instances.*).selections;

    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));

        if (@hasDecl(Plugin, "checkpoint")) {
            var args: std.meta.ArgsTuple(@TypeOf(Plugin.checkpoint)) = undefined;
            args[0] = instances.get(Plugin);

            inline for (@typeInfo(@TypeOf(Plugin.checkpoint)).@"fn".params[1..], 1..) |parameter, argument| {
                args[argument] = if (parameter.type == std.Io) io else try transaction.namespace(Plugin.id);
            }

            try @call(.never_inline, Plugin.checkpoint, args);
        }
    }
}

pub fn close(instances: anytype, io: std.Io, closing: *lifecycle.Closing) void {
    const Selections = @TypeOf(instances.*).selections;

    inline for (0..comptime selection.selectedCount(Selections)) |offset| {
        const index = comptime selection.selectedCount(Selections) - offset - 1;
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));

        if (@hasDecl(Plugin, "close")) {
            if (index < instances.initialized) {
                var args: std.meta.ArgsTuple(@TypeOf(Plugin.close)) = undefined;
                args[0] = instances.get(Plugin);

                inline for (@typeInfo(@TypeOf(Plugin.close)).@"fn".params[1..], 1..) |parameter, argument| {
                    args[argument] = if (parameter.type == std.Io) io else closing;
                }

                @call(.never_inline, Plugin.close, args);
            }
        }
    }

    closing.seal();
}

fn dependencies(comptime T: type, comptime requester: []const u8, instances: anytype, transaction: storage.Transaction, work: *Work, environment: anytype) !T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type == storage.Namespace) {
            @field(result, field.name) = try transaction.namespace(requester);
        } else if (field.type == *Work) {
            @field(result, field.name) = work;
        } else if (selection.dependencyPlugin(field.type)) |Plugin| {
            const Selections = @TypeOf(instances.*).selections;

            if (comptime selection.indexOfId(Selections, Plugin.id) != null) {
                @field(result, field.name) = instances.get(Plugin);
            } else {
                @field(result, field.name) = environmental(field.name, field.type, environment);
            }
        } else {
            @field(result, field.name) = environmental(field.name, field.type, environment);
        }
    }

    return result;
}

fn environmental(comptime name: []const u8, comptime T: type, environment: anytype) T {
    if (@hasField(@TypeOf(environment), name)) {
        return @field(environment, name);
    }

    const Child = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    if (@typeInfo(Child) != .pointer or @typeInfo(Child).pointer.size != .one) {
        if (@typeInfo(T) == .optional) return null;
        @compileError("missing named environment dependency: " ++ name);
    }

    comptime var match: ?[]const u8 = null;

    inline for (@typeInfo(@TypeOf(environment)).@"struct".fields) |field| {
        if (comptime !compatible(T, field.type)) continue;

        if (match != null) @compileError("ambiguous environment dependency: " ++ name);
        match = field.name;
    }

    if (match) |field| return @field(environment, field);
    if (@typeInfo(T) == .optional) return null;
    @compileError("missing environment dependency: " ++ name);
}

fn compatible(comptime Expected: type, comptime Actual: type) bool {
    return Expected == Actual or (@typeInfo(Expected) == .optional and @typeInfo(Expected).optional.child == Actual);
}

fn metadata(comptime T: type, source: anytype) T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@hasField(@TypeOf(source), field.name)) {
            @field(result, field.name) = @field(source, field.name);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            @compileError("missing required plugin metadata: " ++ field.name);
        }
    }

    return result;
}
