const std = @import("std");
const builtin = @import("builtin");
const commands = @import("commands.zig");
const connection_api = @import("connection_api.zig");
const plugin_profiler = @import("plugin_profiler.zig");
const generation_allocator = @import("generation_allocator.zig");

const diagnostics_enabled = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub fn validate(comptime Composition: type) void {
    @setEvalBranchQuota(100_000);
    validateNode(Composition);
    const types = comptime pluginTypes(Composition);
    const plugin_total = types.len;
    inline for (0..plugin_total) |index| {
        const Plugin = types[index];
        inline for (0..index) |previous_index| {
            const Previous = types[previous_index];
            if (comptime std.mem.eql(u8, Plugin.id, Previous.id))
                @compileError("duplicate plugin id '" ++ Plugin.id ++ "'");
        }
    }
}

pub fn count(comptime Composition: type) usize {
    @setEvalBranchQuota(1_000_000);
    if (comptime isPluginPointer(Composition)) return 1;
    const fields = comptime compositionFields(Composition);
    comptime var result: usize = 0;
    inline for (fields) |field| result += comptime count(field.type);
    return result;
}

pub fn traceCount(comptime Composition: type) usize {
    @setEvalBranchQuota(1_000_000);
    if (comptime isPluginPointer(Composition)) return pluginTraceCount(pointerChild(Composition));
    const fields = comptime compositionFields(Composition);
    comptime var result: usize = 0;
    inline for (fields) |field| result += comptime traceCount(field.type);
    return result;
}

pub fn tick(composition: anytype, allocator: std.mem.Allocator) void {
    validate(@TypeOf(composition.*));
    tickNode(composition, allocator, 0, 0);
}

pub fn joined(composition: anytype) void {
    lifecycleForward(composition, "joined", 0);
}

pub fn left(composition: anytype) void {
    lifecycleReverse(composition, "left", 0);
}

pub fn deinit(composition: anytype) void {
    lifecycleReverse(composition, "deinit", 0);
}

pub fn load(composition: anytype) !void {
    try persistenceForward(composition, "load", 0);
}

pub fn save(composition: anytype) !void {
    try persistenceReverse(composition, "save", 0);
}

pub fn loginStart(composition: anytype, draft: *connection_api.LoginDraft) void {
    hookForward(composition, "loginStart", draft);
}

pub fn status(composition: anytype, draft: *connection_api.StatusDraft) void {
    hookForward(composition, "status", draft);
}

pub fn commandDeclarations(comptime Composition: type) [commandCount(Composition)]commands.Declaration {
    validate(Composition);
    var result: [commandCount(Composition)]commands.Declaration = undefined;
    var cursor: usize = 0;
    fillCommands(Composition, &result, &cursor);
    return result;
}

pub fn pluginType(comptime Composition: type, comptime index: usize) type {
    @setEvalBranchQuota(1_000_000);
    if (index >= count(Composition)) @compileError("plugin index is out of bounds");
    return pluginTypes(Composition)[index];
}

pub fn pluginIndex(comptime Composition: type, comptime Plugin: type) usize {
    const types = comptime pluginTypes(Composition);
    inline for (types, 0..) |Candidate, index|
        if (Candidate == Plugin) return index;
    @compileError("plugin '" ++ Plugin.id ++ "' is not present in the composition");
}

pub fn Initializer(comptime Composition: type) type {
    return struct {
        storage: *generation_allocator.Allocator,

        pub fn create(self: @This(), comptime Plugin: type, arguments: anytype) !*Plugin {
            const index = comptime pluginIndex(Composition, Plugin);
            self.storage.beginPlugin(index);
            defer self.storage.endPlugin();
            return @call(.auto, Plugin.create, .{self.storage.allocator()} ++ arguments);
        }
    };
}

pub fn traceBase(comptime Composition: type, comptime plugin_index: usize) usize {
    var result: usize = 0;
    const types = comptime pluginTypes(Composition);
    inline for (0..plugin_index) |index|
        result += pluginTraceCount(types[index]);
    return result;
}

fn tickNode(node: anytype, allocator: std.mem.Allocator, comptime plugin_base: usize, comptime trace_base: usize) void {
    const Node = @TypeOf(node.*);
    if (comptime isPluginPointer(Node)) {
        tickPlugin(node, allocator, plugin_base, trace_base);
        return;
    }
    comptime var next_plugin = plugin_base;
    comptime var next_trace = trace_base;
    inline for (comptime compositionFields(Node)) |field| {
        tickNode(&@field(node, field.name), allocator, next_plugin, next_trace);
        next_plugin += comptime count(field.type);
        next_trace += comptime traceCount(field.type);
    }
}

fn tickPlugin(plugin_pointer: anytype, allocator: std.mem.Allocator, comptime index: usize, comptime trace_base: usize) void {
    const Plugin = pointerChild(@TypeOf(plugin_pointer.*));
    if (!@hasDecl(Plugin, "tick")) return;
    const started = plugin_profiler.beginPlugin(index, trace_base, pluginTraceCount(Plugin));
    const previous = active_system;
    active_system = active(Plugin, "tick", index);
    defer active_system = previous;
    @call(if (diagnostics_enabled) .never_inline else .auto, Plugin.tick, .{ plugin_pointer.*, allocator });
    plugin_profiler.endPlugin(index, started);
}

fn lifecycleForward(node: anytype, comptime name: []const u8, comptime plugin_base: usize) void {
    const Node = @TypeOf(node.*);
    if (comptime isPluginPointer(Node)) return callLifecycle(node.*, name, plugin_base);
    comptime var next = plugin_base;
    inline for (comptime compositionFields(Node)) |field| {
        lifecycleForward(&@field(node, field.name), name, next);
        next += comptime count(field.type);
    }
}

fn lifecycleReverse(node: anytype, comptime name: []const u8, comptime plugin_base: usize) void {
    const Node = @TypeOf(node.*);
    if (comptime isPluginPointer(Node)) return callLifecycle(node.*, name, plugin_base);
    const fields = comptime compositionFields(Node);
    inline for (0..fields.len) |reverse_index| {
        const index = fields.len - 1 - reverse_index;
        const field = fields[index];
        lifecycleReverse(&@field(node, field.name), name, plugin_base + fieldPluginBase(Node, index));
    }
}

fn callLifecycle(plugin: anytype, comptime name: []const u8, comptime index: usize) void {
    const Plugin = pointerChild(@TypeOf(plugin));
    if (!@hasDecl(Plugin, name)) return;
    const started_ns = if (comptime std.mem.eql(u8, name, "deinit"))
        monotonicNanoseconds()
    else
        0;
    defer if (comptime std.mem.eql(u8, name, "deinit")) std.log.info(
        "event=plugin_lifecycle_profile plugin={s} lifecycle=deinit elapsed_ms={d:.3}",
        .{ Plugin.id, elapsedMilliseconds(monotonicNanoseconds() -| started_ns) },
    );
    const previous = active_system;
    active_system = active(Plugin, name, index);
    defer active_system = previous;
    @call(if (diagnostics_enabled) .never_inline else .auto, @field(Plugin, name), .{plugin});
}

fn persistenceForward(node: anytype, comptime name: []const u8, comptime plugin_base: usize) !void {
    const Node = @TypeOf(node.*);
    if (comptime isPluginPointer(Node)) return persistPlugin(node.*, name, plugin_base);
    comptime var next = plugin_base;
    inline for (comptime compositionFields(Node)) |field| {
        try persistenceForward(&@field(node, field.name), name, next);
        next += comptime count(field.type);
    }
}

fn persistenceReverse(node: anytype, comptime name: []const u8, comptime plugin_base: usize) !void {
    const Node = @TypeOf(node.*);
    if (comptime isPluginPointer(Node)) return persistPlugin(node.*, name, plugin_base);
    const fields = comptime compositionFields(Node);
    inline for (0..fields.len) |reverse_index| {
        const index = fields.len - 1 - reverse_index;
        const field = fields[index];
        try persistenceReverse(&@field(node, field.name), name, plugin_base + fieldPluginBase(Node, index));
    }
}

fn persistPlugin(plugin: anytype, comptime name: []const u8, comptime index: usize) !void {
    const Plugin = pointerChild(@TypeOf(plugin));
    if (!@hasDecl(Plugin, name)) return;
    const started_ns = monotonicNanoseconds();
    defer std.log.info(
        "event=plugin_lifecycle_profile plugin={s} lifecycle={s} elapsed_ms={d:.3}",
        .{ Plugin.id, name, elapsedMilliseconds(monotonicNanoseconds() -| started_ns) },
    );
    const previous = active_system;
    active_system = active(Plugin, name, index);
    defer active_system = previous;
    const Return = @typeInfo(@TypeOf(@field(Plugin, name))).@"fn".return_type.?;
    if (comptime Return == void) {
        @call(if (diagnostics_enabled) .never_inline else .auto, @field(Plugin, name), .{plugin});
        return;
    }
    @call(if (diagnostics_enabled) .never_inline else .auto, @field(Plugin, name), .{plugin}) catch |err| {
        std.log.err(
            "event=plugin_lifecycle_failed plugin={s} lifecycle={s} error={s}",
            .{ Plugin.id, name, @errorName(err) },
        );
        return err;
    };
}

fn monotonicNanoseconds() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
        return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(now.nsec));
}

fn elapsedMilliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn hookForward(node: anytype, comptime name: []const u8, argument: anytype) void {
    const Node = @TypeOf(node.*);
    if (comptime isPluginPointer(Node)) {
        const Plugin = pointerChild(Node);
        if (@hasDecl(Plugin, name)) @call(.auto, @field(Plugin, name), .{ node.*, argument });
        return;
    }
    inline for (comptime compositionFields(Node)) |field| hookForward(&@field(node, field.name), name, argument);
}

fn validateNode(comptime Node: type) void {
    if (comptime isPluginPointer(Node)) {
        const Plugin = pointerChild(Node);
        if (Plugin.id.len == 0) @compileError("plugin id must not be empty");
        validateMethod(Plugin, "tick", &.{std.mem.Allocator}, false);
        validateMethod(Plugin, "joined", &.{}, false);
        validateMethod(Plugin, "left", &.{}, false);
        validateMethod(Plugin, "deinit", &.{}, false);
        validateMethod(Plugin, "save", &.{}, true);
        validateMethod(Plugin, "load", &.{}, true);
        validateMethod(Plugin, "loginStart", &.{*connection_api.LoginDraft}, false);
        validateMethod(Plugin, "status", &.{*connection_api.StatusDraft}, false);
        return;
    }
    inline for (comptime compositionFields(Node)) |field| validateNode(field.type);
}

fn validateMethod(comptime Plugin: type, comptime name: []const u8, comptime parameters: []const type, comptime allow_error: bool) void {
    if (!@hasDecl(Plugin, name)) return;
    const info = @typeInfo(@TypeOf(@field(Plugin, name))).@"fn";
    if (info.params.len != parameters.len + 1 or info.params[0].type != *Plugin)
        @compileError(Plugin.id ++ "." ++ name ++ " has an invalid signature");
    inline for (parameters, 0..) |Parameter, index|
        if (info.params[index + 1].type != Parameter)
            @compileError(Plugin.id ++ "." ++ name ++ " has an invalid signature");
    const Return = info.return_type orelse @compileError(Plugin.id ++ "." ++ name ++ " must return a concrete type");
    if (Return != void and (!allow_error or @typeInfo(Return) != .error_union))
        @compileError(Plugin.id ++ "." ++ name ++ " has an invalid return type");
}

fn commandCount(comptime Node: type) usize {
    if (comptime isPluginPointer(Node)) {
        const Plugin = pointerChild(Node);
        return if (@hasDecl(Plugin, "command_declarations")) Plugin.command_declarations.len else 0;
    }
    var result: usize = 0;
    inline for (comptime compositionFields(Node)) |field| result += comptime commandCount(field.type);
    return result;
}

fn fillCommands(comptime Node: type, output: anytype, cursor: *usize) void {
    if (comptime isPluginPointer(Node)) {
        const Plugin = pointerChild(Node);
        if (@hasDecl(Plugin, "command_declarations")) inline for (Plugin.command_declarations) |declaration| {
            output[cursor.*] = declaration;
            cursor.* += 1;
        };
        return;
    }
    inline for (comptime compositionFields(Node)) |field| fillCommands(field.type, output, cursor);
}

fn pluginTypes(comptime Composition: type) [count(Composition)]type {
    @setEvalBranchQuota(1_000_000);
    var result: [count(Composition)]type = undefined;
    var cursor: usize = 0;
    fillPluginTypes(Composition, &result, &cursor);
    return result;
}

fn fillPluginTypes(comptime Node: type, output: anytype, cursor: *usize) void {
    if (comptime isPluginPointer(Node)) {
        output[cursor.*] = pointerChild(Node);
        cursor.* += 1;
        return;
    }
    inline for (comptime compositionFields(Node)) |field|
        fillPluginTypes(field.type, output, cursor);
}

fn fieldPluginBase(comptime Node: type, comptime target: usize) usize {
    comptime var result: usize = 0;
    inline for (comptime compositionFields(Node), 0..) |field, index| {
        if (index < target) result += comptime count(field.type);
    }
    return result;
}

fn compositionFields(comptime T: type) []const std.builtin.Type.StructField {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("plugin composition nodes must be structs containing plugin pointers"),
    };
}

fn isPluginPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .one and @hasDecl(pointer.child, "id"),
        else => false,
    };
}

fn pointerChild(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

fn active(comptime Plugin: type, comptime phase: []const u8, comptime index: usize) ActiveSystem {
    return .{
        .phase = phase,
        .plugin_id = Plugin.id,
        .plugin_index = index,
        .system_type = @typeName(Plugin) ++ "." ++ phase,
        .system_index = 0,
        .tick = null,
        .subject = null,
    };
}

pub const ActiveSystem = struct {
    phase: []const u8,
    plugin_id: []const u8,
    plugin_index: usize,
    system_type: []const u8,
    system_index: usize,
    tick: ?u64,
    subject: ?u16,
};

var active_system: ?ActiveSystem = null;

pub fn activeSystem() ?ActiveSystem {
    return active_system;
}

pub fn pluginTraceCount(comptime Plugin: type) usize {
    if (!@hasDecl(Plugin, "Trace")) return 0;
    return switch (@typeInfo(Plugin.Trace)) {
        .@"enum" => |info| trace_count: {
            inline for (info.fields, 0..) |field, index|
                if (field.value != index)
                    @compileError("plugin " ++ Plugin.id ++ " Trace values must be contiguous from zero");
            break :trace_count info.fields.len;
        },
        else => @compileError("plugin " ++ Plugin.id ++ " Trace must be an enum"),
    };
}
