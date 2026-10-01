const std = @import("std");

const assert = std.debug.assert;
const selection = @import("plugin.zig");
const memory = @import("memory.zig");
const metrics = @import("metrics.zig");
const lifecycle = @import("plugin_lifecycle.zig");
const storage = @import("storage");
const Work = @import("work.zig").Work;

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
        const deps = if (@hasDecl(Plugin, "Dependencies")) try dependencies(Plugin.Dependencies, Plugin.id, instances, transaction, work, environment) else .{};
        const meta = if (@hasField(@TypeOf(environment), "meta")) environment.meta else .{};
        const instance = try selection.initialize(Plugin, allocator.allocator(), io, selections[index].configuration, deps, meta);
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
                args[argument] = if (parameter.type == std.Io) io else if (parameter.type == storage.Namespace) try transaction.namespace(Plugin.id) else if (parameter.type == std.mem.Allocator) temporary.allocator() else @compileError("unsupported tick parameter in plugin " ++ Plugin.id);
            }

            const result = @call(.never_inline, Plugin.tick, args);

            if (@typeInfo(@TypeOf(result)) == .error_union) try result;
            measurements.plugins[index].temporary_bytes = temporary.end_index -| before;
        }
    }
}

pub fn checkpoint(instances: anytype, measurements: *metrics.Metrics, io: std.Io, transaction: storage.Transaction) !void {
    const Selections = @TypeOf(instances.*).selections;

    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));

        if (@hasDecl(Plugin, "checkpoint")) {
            const timing = measurements.enter(index, selection.traceBase(Selections, index), selection.pluginTraceCount(Plugin));
            var args: std.meta.ArgsTuple(@TypeOf(Plugin.checkpoint)) = undefined;
            args[0] = instances.get(Plugin);

            inline for (@typeInfo(@TypeOf(Plugin.checkpoint)).@"fn".params[1..], 1..) |parameter, argument| {
                args[argument] = if (parameter.type == std.Io) io else if (parameter.type == storage.Namespace) try transaction.namespace(Plugin.id) else @compileError("unsupported checkpoint parameter in plugin " ++ Plugin.id);
            }

            const result = @call(.never_inline, Plugin.checkpoint, args);
            timing.end();
            if (measurements.recorder.enabled and measurements.plugins[index].last_ns >= 20 * std.time.ns_per_ms)
                std.log.warn("event=slow_checkpoint plugin={s} ns={d}", .{ Plugin.id, measurements.plugins[index].last_ns });
            try result;
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
                selection.close(Plugin, instances.get(Plugin), io, closing);
            }
        }
    }

    closing.seal();
}

fn dependencies(comptime T: type, comptime requester: []const u8, instances: anytype, transaction: storage.Transaction, work: *Work, environment: anytype) !T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        const Selections = @TypeOf(instances.*).selections;
        if (field.type == storage.Namespace) {
            @field(result, field.name) = try transaction.namespace(requester);
        } else if (field.type == *Work) {
            @field(result, field.name) = work;
        } else {
            const before = comptime selection.indexOfId(Selections, requester).?;
            @field(result, field.name) = selection.dependency(field.name, field.type, instances, environment, before);
        }
    }

    return result;
}
