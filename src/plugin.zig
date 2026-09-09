const std = @import("std");
const commands = @import("commands.zig");
const persistence = @import("persistence.zig");

pub fn configured(comptime Plugin: type, configuration: Plugin.Configuration) Selection(Plugin) {
    return .{ .configuration = configuration };
}

pub fn Selection(comptime Plugin: type) type {
    return struct {
        pub const plugin = Plugin;
        configuration: Plugin.Configuration,
    };
}

pub fn SelectionTuple(comptime Plugins: type) type {
    const fields = comptime tupleFields(Plugins);
    comptime var result: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| result[index] = Selection(field.type);
    return std.meta.Tuple(&result);
}

pub fn selectedCount(comptime Selections: type) usize {
    return (comptime tupleFields(Selections)).len;
}

pub fn minimumTickScratchBytes(comptime Selections: type) usize {
    return comptime total: {
        var bytes: usize = 0;
        for (tupleFields(Selections)) |field| {
            const Plugin = selectedPlugin(field.type);
            if (@hasDecl(Plugin, "tick_scratch_bytes")) bytes += Plugin.tick_scratch_bytes;
        }
        break :total bytes;
    };
}

pub fn traceCount(comptime Selections: type) usize {
    var count: usize = 0;
    inline for (comptime tupleFields(Selections)) |field|
        count += pluginTraceCount(selectedPlugin(field.type));
    return count;
}

pub fn closeTokenCount(comptime Selections: type) usize {
    var count: usize = 0;
    inline for (comptime tupleFields(Selections)) |field| {
        const Plugin = selectedPlugin(field.type);
        if (@hasDecl(Plugin, "close")) count += 1;
    }
    return count;
}

pub fn traceBase(comptime Selections: type, comptime plugin_index: usize) usize {
    const selected_count = comptime selectedCount(Selections);
    if (plugin_index >= selected_count)
        @compileError("plugin trace index is out of bounds");
    var count: usize = 0;
    inline for (comptime tupleFields(Selections)[0..plugin_index]) |field|
        count += pluginTraceCount(selectedPlugin(field.type));
    return count;
}

pub fn pluginTraceCount(comptime Plugin: type) usize {
    if (!@hasDecl(Plugin, "Trace")) return 0;
    const info = @typeInfo(Plugin.Trace);
    if (info != .@"enum") @compileError(Plugin.id ++ ".Trace must be an enum");
    inline for (info.@"enum".fields, 0..) |field, index| {
        if (field.value != index)
            @compileError(Plugin.id ++ ".Trace values must be contiguous from zero");
    }
    return info.@"enum".fields.len;
}

pub fn selectedType(comptime Selections: type, comptime index: usize) type {
    const fields = comptime tupleFields(Selections);
    if (index >= fields.len) @compileError("plugin selection index is out of bounds");
    return fields[index].type;
}

pub fn selectedPlugin(comptime Selected: type) type {
    if (!@hasDecl(Selected, "plugin"))
        @compileError("plugin selections must be made with plugin.configured");
    return Selected.plugin;
}

pub fn commandDeclarations(comptime Selections: type) [commandDeclarationCount(Selections)]commands.Declaration {
    var result: [commandDeclarationCount(Selections)]commands.Declaration = undefined;
    var cursor: usize = 0;
    inline for (comptime tupleFields(Selections)) |field| {
        const Plugin = selectedPlugin(field.type);
        if (!@hasDecl(Plugin, "command_declarations")) continue;
        inline for (Plugin.command_declarations) |declaration| {
            result[cursor] = declaration;
            cursor += 1;
        }
    }
    std.debug.assert(cursor == result.len);
    return result;
}

pub fn commandDeclarationCount(comptime Selections: type) usize {
    var count: usize = 0;
    inline for (comptime tupleFields(Selections)) |field| {
        const Plugin = selectedPlugin(field.type);
        if (@hasDecl(Plugin, "command_declarations"))
            count += Plugin.command_declarations.len;
    }
    return count;
}

pub fn indexOfId(comptime Selections: type, comptime id: []const u8) ?usize {
    @setEvalBranchQuota(20_000_000);
    inline for (comptime tupleFields(Selections), 0..) |field, index| {
        if (comptime std.mem.eql(u8, selectedPlugin(field.type).id, id)) return index;
    }
    return null;
}

pub fn typeOfId(comptime Selections: type, comptime id: []const u8) ?type {
    const index = indexOfId(Selections, id) orelse return null;
    return selectedPlugin(selectedType(Selections, index));
}

pub fn compose(parts: anytype) Compose(@TypeOf(parts)) {
    const fields = comptime tupleFields(@TypeOf(parts));
    var result: Compose(@TypeOf(parts)) = undefined;
    comptime var cursor: usize = 0;
    inline for (fields) |field| {
        const value = @field(parts, field.name);
        if (comptime isSelection(field.type)) {
            result[cursor] = value;
            cursor += 1;
        } else {
            inline for (comptime tupleFields(field.type)) |nested| {
                result[cursor] = @field(value, nested.name);
                cursor += 1;
            }
        }
    }
    std.debug.assert(cursor == result.len);
    return result;
}

pub fn remove(selections: anytype, comptime Plugin: type) Remove(@TypeOf(selections), Plugin) {
    const removed = comptime indexOfPlugin(@TypeOf(selections), Plugin) orelse
        @compileError("cannot remove a plugin that is not selected: " ++ Plugin.id);
    var result: Remove(@TypeOf(selections), Plugin) = undefined;
    inline for (0..removed) |index| result[index] = selections[index];
    inline for (removed + 1..selections.len) |index| result[index - 1] = selections[index];
    return result;
}

pub fn replace(selections: anytype, replacements: anytype) Replace(@TypeOf(selections), @TypeOf(replacements)) {
    comptime validateReplacements(@TypeOf(selections), @TypeOf(replacements));
    var result: Replace(@TypeOf(selections), @TypeOf(replacements)) = undefined;
    inline for (comptime tupleFields(@TypeOf(selections)), 0..) |field, index| {
        const id = selectedPlugin(field.type).id;
        if (comptime replacementIndex(@TypeOf(replacements), id)) |replacement|
            result[index] = replacements[replacement]
        else
            result[index] = selections[index];
    }
    return result;
}

pub fn insertAfter(selections: anytype, comptime Anchor: type, inserted: anytype) InsertAfter(@TypeOf(selections), Anchor, @TypeOf(inserted)) {
    const index = comptime indexOfPlugin(@TypeOf(selections), Anchor) orelse
        @compileError("cannot insert after a plugin that is not selected: " ++ Anchor.id);
    var result: InsertAfter(@TypeOf(selections), Anchor, @TypeOf(inserted)) = undefined;
    inline for (0..index + 1) |source| result[source] = selections[source];
    result[index + 1] = inserted;
    inline for (index + 1..selections.len) |source| result[source + 1] = selections[source];
    return result;
}

pub fn Compose(comptime Parts: type) type {
    @setEvalBranchQuota(20_000_000);
    const fields = comptime tupleFields(Parts);
    comptime var count: usize = 0;
    inline for (fields) |field| count += partCount(field.type);
    comptime var result: [count]type = undefined;
    comptime var cursor: usize = 0;
    inline for (fields) |field| {
        if (isSelection(field.type)) {
            result[cursor] = field.type;
            cursor += 1;
        } else {
            inline for (tupleFields(field.type)) |nested| {
                result[cursor] = nested.type;
                cursor += 1;
            }
        }
    }
    return std.meta.Tuple(&result);
}

pub fn Remove(comptime Selections: type, comptime Plugin: type) type {
    const fields = comptime tupleFields(Selections);
    const removed = comptime indexOfPlugin(Selections, Plugin) orelse @compileError("plugin is not selected: " ++ Plugin.id);
    comptime var result: [fields.len - 1]type = undefined;
    inline for (0..removed) |index| result[index] = fields[index].type;
    inline for (removed + 1..fields.len) |index| result[index - 1] = fields[index].type;
    return std.meta.Tuple(&result);
}

pub fn Replace(comptime Selections: type, comptime Replacements: type) type {
    const fields = comptime tupleFields(Selections);
    comptime validateReplacements(Selections, Replacements);
    comptime var result: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| {
        const id = selectedPlugin(field.type).id;
        result[index] = if (replacementIndex(Replacements, id)) |replacement|
            tupleFields(Replacements)[replacement].type
        else
            field.type;
    }
    return std.meta.Tuple(&result);
}

fn validateReplacements(comptime Selections: type, comptime Replacements: type) void {
    const fields = tupleFields(Replacements);
    if (fields.len == 0) @compileError("plugin.replace requires at least one replacement");
    inline for (fields, 0..) |field, index| {
        if (!isSelection(field.type)) @compileError("plugin.replace accepts plugin selections");
        const Replacement = selectedPlugin(field.type);
        if (indexOfId(Selections, Replacement.id) == null)
            @compileError("cannot replace a plugin that is not selected: " ++ Replacement.id);
        inline for (fields[0..index]) |previous| {
            if (std.mem.eql(u8, Replacement.id, selectedPlugin(previous.type).id))
                @compileError("duplicate plugin replacement: " ++ Replacement.id);
        }
    }
}

fn replacementIndex(comptime Replacements: type, comptime id: []const u8) ?usize {
    inline for (tupleFields(Replacements), 0..) |field, index|
        if (std.mem.eql(u8, id, selectedPlugin(field.type).id)) return index;
    return null;
}

pub fn InsertAfter(comptime Selections: type, comptime Anchor: type, comptime Inserted: type) type {
    const fields = comptime tupleFields(Selections);
    const index = comptime indexOfPlugin(Selections, Anchor) orelse @compileError("plugin is not selected: " ++ Anchor.id);
    comptime var result: [fields.len + 1]type = undefined;
    inline for (0..index + 1) |source| result[source] = fields[source].type;
    result[index + 1] = Inserted;
    inline for (index + 1..fields.len) |source| result[source + 1] = fields[source].type;
    return std.meta.Tuple(&result);
}

fn indexOfPlugin(comptime Selections: type, comptime Plugin: type) ?usize {
    inline for (comptime tupleFields(Selections), 0..) |field, index| {
        if (comptime selectedPlugin(field.type) == Plugin) return index;
    }
    return null;
}

pub fn validate(comptime Selections: type) void {
    const fields = comptime tupleFields(Selections);
    @setEvalBranchQuota(1_000 + fields.len * fields.len * 32);
    inline for (fields, 0..) |field, index| {
        const Plugin = selectedPlugin(field.type);
        validatePlugin(Plugin);
        inline for (fields[0..index]) |previous| {
            if (comptime std.mem.eql(u8, Plugin.id, selectedPlugin(previous.type).id))
                @compileError("duplicate plugin id: " ++ Plugin.id);
        }
        validateDependencies(Selections, Plugin, index);
    }
}

fn validatePlugin(comptime Plugin: type) void {
    if (@typeInfo(Plugin) != .@"struct") @compileError("a plugin must be a struct");
    if (!@hasDecl(Plugin, "id") or Plugin.id.len == 0)
        @compileError("a plugin must declare a non-empty pub const id: []const u8");
    if (!@hasDecl(Plugin, "Configuration") or @typeInfo(Plugin.Configuration) != .@"struct")
        @compileError(Plugin.id ++ " must declare pub const Configuration = struct { ... }");
    if (!@hasDecl(Plugin, "init")) @compileError(Plugin.id ++ " must declare init");
    validateDependenciesType(Plugin);
    if (@hasDecl(Plugin, "Meta") and @typeInfo(Plugin.Meta) != .@"struct")
        @compileError(Plugin.id ++ ".Meta must be a struct");
    _ = pluginTraceCount(Plugin);
    validateInit(Plugin);
    validateLifecycle(Plugin);
}

fn validateDependenciesType(comptime Plugin: type) void {
    if (!@hasDecl(Plugin, "Dependencies")) return;
    if (@typeInfo(Plugin.Dependencies) != .@"struct")
        @compileError(Plugin.id ++ ".Dependencies must be a struct");
    inline for (@typeInfo(Plugin.Dependencies).@"struct".fields) |field| {
        const Dependency = dependencyPlugin(field.type) orelse continue;
        if (@typeInfo(Dependency) != .@"struct" or !@hasDecl(Dependency, "id") or Dependency.id.len == 0)
            @compileError(Plugin.id ++ " dependency must point to a plugin struct with an id");
    }
}

fn validateInit(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.init)).@"fn";
    var seen: u8 = 0;
    for (info.params) |parameter| {
        const T = parameter.type orelse @compileError(Plugin.id ++ ".init requires typed parameters");
        const bit: u8 = if (T == std.mem.Allocator) 1 else if (T == std.Io) 2 else if (T == Plugin.Configuration) 4 else if (@hasDecl(Plugin, "Dependencies") and T == Plugin.Dependencies) 8 else if (@hasDecl(Plugin, "Meta") and T == Plugin.Meta) 16 else @compileError(Plugin.id ++ ".init has an unsupported parameter");
        if (seen & bit != 0) @compileError(Plugin.id ++ ".init has a duplicate injected parameter");
        seen |= bit;
    }
    const expected: u8 = 1 | 4 | @as(u8, if (@hasDecl(Plugin, "Dependencies")) 8 else 0) | @as(u8, if (@hasDecl(Plugin, "Meta")) 16 else 0);
    if (seen & ~@as(u8, 2) != expected)
        @compileError(Plugin.id ++ ".init requires Allocator, Configuration, and its declared Dependencies/Meta; std.Io is optional");
    const result = info.return_type orelse @compileError(Plugin.id ++ ".init must return !*Self");
    if (@typeInfo(result) != .error_union or @typeInfo(result).error_union.payload != *Plugin)
        @compileError(Plugin.id ++ ".init must return !*Self");
}

fn validateLifecycle(comptime Plugin: type) void {
    if (@hasDecl(Plugin, "tick")) validateTick(Plugin);
    if (@hasDecl(Plugin, "checkpoint")) validateCheckpoint(Plugin);
    if (@hasDecl(Plugin, "close")) validateClose(Plugin);
}

fn validateTick(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.tick)).@"fn";
    const result = info.return_type orelse @compileError(Plugin.id ++ ".tick requires an explicit return type");
    if (result != void) {
        const fatal = @import("plugin_lifecycle.zig").FatalError;
        if (@typeInfo(result) != .error_union or @typeInfo(result).error_union.payload != void or
            (@typeInfo(result).error_union.error_set || fatal) != fatal)
            @compileError(Plugin.id ++ ".tick must return void or a subset of plugin_lifecycle.FatalError!void");
    }
    if (info.params.len < 1 or info.params.len > 3 or info.params[0].type != *Plugin)
        @compileError(Plugin.id ++ ".tick must take *Self and optionally Allocator and std.Io");
    var seen: u8 = 0;
    for (info.params[1..]) |parameter| {
        const bit: u8 = if (parameter.type == std.mem.Allocator) 1 else if (parameter.type == std.Io) 2 else @compileError(Plugin.id ++ ".tick accepts only Allocator and std.Io after *Self");
        if (seen & bit != 0) @compileError(Plugin.id ++ ".tick has a duplicate injected parameter");
        seen |= bit;
    }
}

fn validateCheckpoint(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.checkpoint)).@"fn";
    const lifecycle = @import("plugin_lifecycle.zig");
    const result = info.return_type orelse
        @compileError(Plugin.id ++ ".checkpoint must return !void");
    if (info.params.len < 2 or info.params.len > 3 or info.params[0].type != *Plugin or
        @typeInfo(result) != .error_union or
        @typeInfo(result).error_union.payload != void)
        @compileError(Plugin.id ++ ".checkpoint requires *Self, *Checkpoint.NamespaceWriter, optional std.Io and an error union void result");
    var seen: u8 = 0;
    for (info.params[1..]) |parameter| {
        const bit: u8 = if (parameter.type == *lifecycle.Checkpoint.NamespaceWriter) 1 else if (parameter.type == std.Io) 2 else @compileError(Plugin.id ++ ".checkpoint accepts only *Checkpoint.NamespaceWriter and std.Io after *Self");
        if (seen & bit != 0) @compileError(Plugin.id ++ ".checkpoint has a duplicate injected parameter");
        seen |= bit;
    }
    if (seen & 1 == 0) @compileError(Plugin.id ++ ".checkpoint requires *Checkpoint.NamespaceWriter");
}

fn validateClose(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.close)).@"fn";
    const lifecycle = @import("plugin_lifecycle.zig");
    if (info.params.len < 2 or info.params.len > 3 or info.params[0].type != *Plugin or info.return_type != void)
        @compileError(Plugin.id ++ ".close requires *Self, *Closing, optional std.Io and a void result");
    var seen: u8 = 0;
    for (info.params[1..]) |parameter| {
        const bit: u8 = if (parameter.type == *lifecycle.Closing) 1 else if (parameter.type == std.Io) 2 else @compileError(Plugin.id ++ ".close accepts only *Closing and std.Io after *Self");
        if (seen & bit != 0) @compileError(Plugin.id ++ ".close has a duplicate injected parameter");
        seen |= bit;
    }
    if (seen & 1 == 0) @compileError(Plugin.id ++ ".close requires *Closing");
}

fn validateDependencies(comptime Selections: type, comptime Plugin: type, comptime plugin_index: usize) void {
    inline for (@typeInfo(dependenciesType(Plugin)).@"struct".fields) |field| {
        const Dependency = dependencyPlugin(field.type) orelse continue;
        const found = comptime indexOfId(Selections, Dependency.id);
        if (found == null and !isOptional(field.type))
            @compileError("plugin '" ++ Plugin.id ++ "' depends on missing plugin '" ++ Dependency.id ++ "'");
        if (found) |index| if (index >= plugin_index)
            @compileError("plugin dependencies must appear earlier: '" ++ Plugin.id ++ "' -> '" ++ Dependency.id ++ "'");
    }
}

pub fn dependenciesType(comptime Plugin: type) type {
    return if (@hasDecl(Plugin, "Dependencies")) Plugin.Dependencies else struct {};
}

fn dependencyPlugin(comptime T: type) ?type {
    if (T == persistence.PluginAccess) return null;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| if (isPlugin(pointer.child)) pointer.child else null,
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .pointer => |pointer| if (isPlugin(pointer.child)) pointer.child else null,
            else => @compileError("an optional dependency must be ?*Plugin"),
        },
        else => @compileError("a dependency must be *Plugin or ?*Plugin"),
    };
}

fn isPlugin(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "id");
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn partCount(comptime Part: type) usize {
    if (isSelection(Part)) return 1;
    return tupleFields(Part).len;
}

fn isSelection(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "plugin");
}

fn tupleFields(comptime Selections: type) []const std.builtin.Type.StructField {
    const info = @typeInfo(Selections);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("plugin selections must be a tuple");
    return info.@"struct".fields;
}

test "composition is explicit and keyed by stable id" {
    const First = struct {
        pub const id = "test:first";
        pub const Configuration = struct {};
        pub fn init(a: std.mem.Allocator, _: Configuration) !*@This() {
            return a.create(@This());
        }
    };
    const Second = struct {
        pub const id = "test:second";
        pub const Configuration = struct { value: u8 };
        pub fn init(a: std.mem.Allocator, _: Configuration) !*@This() {
            return a.create(@This());
        }
    };
    const selected = .{ configured(First, .{}), configured(Second, .{ .value = 3 }) };
    try std.testing.expectEqual(@as(?usize, 0), indexOfId(@TypeOf(selected), "test:first"));
    try std.testing.expectEqual(@as(?usize, 0), indexOfPlugin(@TypeOf(selected), First));
    const Trimmed = Remove(@TypeOf(selected), First);
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Trimmed).@"struct".fields.len);
    const changed = replace(selected, .{configured(Second, .{ .value = 9 })});
    try std.testing.expectEqual(@as(u8, 9), changed[1].configuration.value);
    try std.testing.expectEqual(@as(usize, 1), remove(changed, First).len);
}

test "compose validates dependencies against the composed selection" {
    const Foundation = struct {
        pub const id = "test:foundation";
        pub const Configuration = struct {};
        pub fn init(allocator: std.mem.Allocator, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const Extension = struct {
        pub const id = "test:extension";
        pub const Configuration = struct {};
        pub const Dependencies = struct { foundation: *Foundation };
        pub fn init(allocator: std.mem.Allocator, _: Dependencies, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const base = .{configured(Foundation, .{})};
    const combined = compose(.{ base, configured(Extension, .{}) });
    comptime validate(@TypeOf(combined));
    try std.testing.expectEqual(@as(usize, 2), combined.len);
}

test "insertAfter preserves the explicit scheduling boundary" {
    const First = struct {
        pub const id = "test:insert-first";
        pub const Configuration = struct {};
        pub fn init(allocator: std.mem.Allocator, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const Middle = struct {
        pub const id = "test:insert-middle";
        pub const Configuration = struct {};
        pub const Dependencies = struct { first: *First };
        pub fn init(allocator: std.mem.Allocator, _: Dependencies, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const Last = struct {
        pub const id = "test:insert-last";
        pub const Configuration = struct {};
        pub fn init(allocator: std.mem.Allocator, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const base = .{ configured(First, .{}), configured(Last, .{}) };
    const selected = insertAfter(base, First, configured(Middle, .{}));
    comptime validate(@TypeOf(selected));
    try std.testing.expectEqual(@as(?usize, 1), indexOfPlugin(@TypeOf(selected), Middle));
}

test "compose flattens baselines and configured extensions in source order" {
    const First = struct {
        pub const id = "test:compose-first";
        pub const Configuration = struct {};
        pub fn init(allocator: std.mem.Allocator, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const Second = struct {
        pub const id = "test:compose-second";
        pub const Configuration = struct {};
        pub const Dependencies = struct { first: *First };
        pub fn init(allocator: std.mem.Allocator, _: Dependencies, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const Third = struct {
        pub const id = "test:compose-third";
        pub const Configuration = struct {};
        pub fn init(allocator: std.mem.Allocator, _: Configuration) !*@This() {
            return allocator.create(@This());
        }
    };
    const baseline = .{ configured(First, .{}), configured(Second, .{}) };
    const composed = compose(.{ baseline, configured(Third, .{}) });
    comptime validate(@TypeOf(composed));
    try std.testing.expectEqual(@as(?usize, 0), indexOfPlugin(@TypeOf(composed), First));
    try std.testing.expectEqual(@as(?usize, 1), indexOfPlugin(@TypeOf(composed), Second));
    try std.testing.expectEqual(@as(?usize, 2), indexOfPlugin(@TypeOf(composed), Third));
}
