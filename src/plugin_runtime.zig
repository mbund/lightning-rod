const std = @import("std");
const selection = @import("plugin.zig");
const PluginAllocator = @import("plugin_allocator.zig").PluginAllocator;
const metrics = @import("metrics");
const lifecycle = @import("plugin_lifecycle.zig");
const storage = @import("storage");
const Work = @import("work.zig").Work;

const assert = std.debug.assert;

pub const Instruments = struct {
    initialization: metrics.Timer,
    tick: metrics.Timer,
    checkpoint: metrics.Timer,
    work: metrics.Timer,
    persistent_bytes: metrics.Gauge,
    temporary_bytes: metrics.Gauge,
};

pub fn initialize(instances: anytype, selections: @TypeOf(instances.*).selections, allocator: *PluginAllocator, registry: *metrics.Registry, instruments: []Instruments, io: std.Io, transaction: storage.Transaction, work: *Work, environment: anytype) !void {
    const Selections = @TypeOf(instances.*).selections;
    assert(instances.initialized == 0);

    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));
        instruments[index] = .{
            .initialization = try registry.timer(.{ .namespace = Plugin.id, .name = "initialize", .description = "Plugin initialization duration" }),
            .tick = try registry.timer(.{ .namespace = Plugin.id, .name = "tick", .description = "Plugin tick duration" }),
            .checkpoint = try registry.timer(.{ .namespace = Plugin.id, .name = "checkpoint", .description = "Plugin checkpoint duration" }),
            .work = try registry.timer(.{ .namespace = Plugin.id, .name = "work", .description = "Plugin background work duration" }),
            .persistent_bytes = try registry.gauge(.{ .namespace = Plugin.id, .name = "persistent_memory", .description = "Plugin permanent allocations", .unit = .bytes }),
            .temporary_bytes = try registry.gauge(.{ .namespace = Plugin.id, .name = "temporary_memory", .description = "Plugin tick scratch allocations", .unit = .bytes }),
        };
        work.registration_timer = instruments[index].work;
        allocator.beginPlugin(index);
        defer allocator.endPlugin();
        const timing = instruments[index].initialization.start();
        defer timing.end();
        const deps = if (@hasDecl(Plugin, "Dependencies")) try dependencies(Plugin.Dependencies, Plugin.id, instances, transaction, work, environment) else .{};
        const meta = if (@hasField(@TypeOf(environment), "meta")) environment.meta else .{};
        const instance = try selection.initialize(Plugin, allocator.allocator(), io, selections[index].configuration, deps, meta);
        if (!allocator.ownsCurrentPluginAllocation(instance)) return error.PluginAllocationInvalid;
        instruments[index].persistent_bytes.set(allocator.currentPluginBytes());
        instances.pointers[index] = instance;
        instances.initialized += 1;
    }
}

pub fn tick(instances: anytype, temporary: *std.heap.FixedBufferAllocator, instruments: []Instruments, io: std.Io, transaction: storage.Transaction) !void {
    const Selections = @TypeOf(instances.*).selections;
    assert(instances.initialized == selection.selectedCount(Selections));

    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));

        if (@hasDecl(Plugin, "tick")) {
            const timing = instruments[index].tick.start();
            defer timing.end();
            const before = temporary.end_index;
            var args: std.meta.ArgsTuple(@TypeOf(Plugin.tick)) = undefined;
            args[0] = instances.get(Plugin);

            inline for (@typeInfo(@TypeOf(Plugin.tick)).@"fn".params[1..], 1..) |parameter, argument| {
                args[argument] = if (parameter.type == std.Io) io else if (parameter.type == storage.Space) try transaction.openSpace(Plugin.id) else if (parameter.type == std.mem.Allocator) temporary.allocator() else @compileError("unsupported tick parameter in plugin " ++ Plugin.id);
            }

            const result = @call(.never_inline, Plugin.tick, args);

            if (@typeInfo(@TypeOf(result)) == .error_union) try result;
            instruments[index].temporary_bytes.set(temporary.end_index -| before);
        }
    }
}

/// Scratch allocations expire when each plugin's checkpoint returns.
pub fn checkpoint(instances: anytype, temporary: *std.heap.FixedBufferAllocator, instruments: []Instruments, io: std.Io, transaction: storage.Transaction) !void {
    const Selections = @TypeOf(instances.*).selections;
    defer temporary.reset();

    inline for (0..comptime selection.selectedCount(Selections)) |index| {
        const Plugin = selection.selectedPlugin(selection.selectedType(Selections, index));

        if (@hasDecl(Plugin, "checkpoint")) {
            temporary.reset();
            const timing = instruments[index].checkpoint.start();
            defer timing.end();
            var args: std.meta.ArgsTuple(@TypeOf(Plugin.checkpoint)) = undefined;
            args[0] = instances.get(Plugin);

            inline for (@typeInfo(@TypeOf(Plugin.checkpoint)).@"fn".params[1..], 1..) |parameter, argument| {
                args[argument] = if (parameter.type == std.Io) io else if (parameter.type == storage.Space) try transaction.openSpace(Plugin.id) else if (parameter.type == std.mem.Allocator) temporary.allocator() else @compileError("unsupported checkpoint parameter in plugin " ++ Plugin.id);
            }

            const result = @call(.never_inline, Plugin.checkpoint, args);
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
        if (field.type == storage.Space) {
            @field(result, field.name) = try transaction.openSpace(requester);
        } else if (field.type == *Work) {
            @field(result, field.name) = work;
        } else {
            const before = comptime selection.indexOfId(Selections, requester).?;
            @field(result, field.name) = selection.dependency(field.name, field.type, instances, environment, before);
        }
    }

    return result;
}
