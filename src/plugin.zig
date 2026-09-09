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

pub fn configure(selections: anytype, comptime Plugin: type, configuration: Plugin.Configuration) void {
    const Pointer = @TypeOf(selections);
    if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one)
        @compileError("plugin.configure expects a pointer to a plugin selection tuple");
    const Selections = @typeInfo(Pointer).pointer.child;
    const index = comptime indexOfPlugin(Selections, Plugin) orelse
        @compileError("cannot configure a plugin that is not selected: " ++ Plugin.id);
    selections.*[index].configuration = configuration;
}

pub fn remove(selections: anytype, comptime Plugin: type) Remove(@TypeOf(selections), Plugin) {
    const removed = comptime indexOfPlugin(@TypeOf(selections), Plugin) orelse
        @compileError("cannot remove a plugin that is not selected: " ++ Plugin.id);
    var result: Remove(@TypeOf(selections), Plugin) = undefined;
    inline for (0..removed) |index| result[index] = selections[index];
    inline for (removed + 1..selections.len) |index| result[index - 1] = selections[index];
    return result;
}

pub fn replace(selections: anytype, comptime Old: type, replacement: anytype) Replace(@TypeOf(selections), Old, @TypeOf(replacement)) {
    const index = comptime indexOfPlugin(@TypeOf(selections), Old) orelse
        @compileError("cannot replace a plugin that is not selected: " ++ Old.id);
    if (comptime !std.mem.eql(u8, selectedPlugin(@TypeOf(replacement)).id, Old.id))
        @compileError("replacement plugin id must equal the replaced plugin id");
    var result: Replace(@TypeOf(selections), Old, @TypeOf(replacement)) = undefined;
    inline for (0..selections.len) |source| result[source] = if (source == index) replacement else selections[source];
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

pub fn Replace(comptime Selections: type, comptime Old: type, comptime Replacement: type) type {
    const fields = comptime tupleFields(Selections);
    const index = comptime indexOfPlugin(Selections, Old) orelse @compileError("plugin is not selected: " ++ Old.id);
    comptime var result: [fields.len]type = undefined;
    inline for (fields, 0..) |field, field_index|
        result[field_index] = if (field_index == index) Replacement else field.type;
    return std.meta.Tuple(&result);
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
    const expected_parameters: usize = 1 + @as(usize, @intFromBool(@hasDecl(Plugin, "Dependencies"))) +
        1 +
        @as(usize, @intFromBool(@hasDecl(Plugin, "Meta")));
    if (info.params.len != expected_parameters or info.params[0].type != std.mem.Allocator)
        @compileError(Plugin.id ++ ".init must be fn (Allocator, [Dependencies,] Configuration, [Meta,]) !*Self");
    if (@hasDecl(Plugin, "Dependencies") and info.params[1].type != Plugin.Dependencies)
        @compileError(Plugin.id ++ ".init Dependencies parameter must be its Dependencies type");
    if (info.params[1 + @as(usize, @intFromBool(@hasDecl(Plugin, "Dependencies")))].type != Plugin.Configuration)
        @compileError(Plugin.id ++ ".init Configuration parameter must be its Configuration type");
    if (@hasDecl(Plugin, "Meta") and info.params[info.params.len - 1].type != Plugin.Meta)
        @compileError(Plugin.id ++ ".init Meta parameter must be its Meta type");
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
    if (info.return_type != void or info.params.len < 1 or info.params.len > 2 or info.params[0].type != *Plugin)
        @compileError(Plugin.id ++ ".tick must be fn (*Self) void or fn (*Self, Allocator) void");
    if (info.params.len == 2 and info.params[1].type != std.mem.Allocator)
        @compileError(Plugin.id ++ ".tick's optional second parameter must be Allocator");
}

fn validateCheckpoint(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.checkpoint)).@"fn";
    const lifecycle = @import("plugin_lifecycle.zig");
    const result = info.return_type orelse
        @compileError(Plugin.id ++ ".checkpoint must return !void");
    if (info.params.len != 2 or info.params[0].type != *Plugin or
        info.params[1].type != *lifecycle.Checkpoint.NamespaceWriter or
        @typeInfo(result) != .error_union or
        @typeInfo(result).error_union.payload != void)
        @compileError(Plugin.id ++ ".checkpoint must be fn (*Self, *Checkpoint.NamespaceWriter) !void");
}

fn validateClose(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.close)).@"fn";
    const lifecycle = @import("plugin_lifecycle.zig");
    if (info.params.len != 2 or info.params[0].type != *Plugin or
        info.params[1].type != *lifecycle.Closing or info.return_type != void)
        @compileError(Plugin.id ++ ".close must be fn (*Self, *Closing) void");
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
    var selected = .{ configured(First, .{}), configured(Second, .{ .value = 3 }) };
    try std.testing.expectEqual(@as(?usize, 0), indexOfId(@TypeOf(selected), "test:first"));
    try std.testing.expectEqual(@as(?usize, 0), indexOfPlugin(@TypeOf(selected), First));
    configure(&selected, Second, .{ .value = 7 });
    try std.testing.expectEqual(@as(u8, 7), selected[1].configuration.value);
    const Trimmed = Remove(@TypeOf(selected), First);
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Trimmed).@"struct".fields.len);
    const changed = replace(selected, Second, configured(Second, .{ .value = 9 }));
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
