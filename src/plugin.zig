const std = @import("std");
const lifecycle = @import("plugin_lifecycle.zig");
const storage = @import("storage");

pub fn initialize(comptime Plugin: type, allocator: std.mem.Allocator, io: std.Io, configuration: Plugin.Configuration, dependencies: anytype, source: anytype) !*Plugin {
    return construct(Plugin, Plugin.init, allocator, io, configuration, dependencies, source);
}

/// Persistent plugins share their allocation path with init and defer storage access to init.
pub fn reserve(comptime Plugin: type, allocator: std.mem.Allocator, io: std.Io, configuration: Plugin.Configuration, dependencies: anytype, source: anytype) !*Plugin {
    if (@hasDecl(Plugin, "Dependencies")) {
        inline for (@typeInfo(Plugin.Dependencies).@"struct".field_types) |field| {
            if (field == storage.Space and !@hasDecl(Plugin, "allocate"))
                @compileError("persistent plugin must provide allocation without storage access: " ++ Plugin.id);
        }
    }
    return construct(Plugin, if (@hasDecl(Plugin, "allocate")) Plugin.allocate else Plugin.init, allocator, io, configuration, dependencies, source);
}

fn construct(comptime Plugin: type, comptime constructor: anytype, allocator: std.mem.Allocator, io: std.Io, configuration: Plugin.Configuration, dependencies: anytype, source: anytype) !*Plugin {
    var args: std.meta.ArgsTuple(@TypeOf(constructor)) = undefined;

    inline for (@typeInfo(@TypeOf(constructor)).@"fn".param_types, 0..) |parameter, argument| {
        const T = parameter.?;
        args[argument] = if (T == std.mem.Allocator) allocator else if (T == std.Io) io else if (T == Plugin.Configuration) configuration else if (@hasDecl(Plugin, "Dependencies") and T == Plugin.Dependencies) dependencies else if (@hasDecl(Plugin, "Meta") and T == Plugin.Meta) metadata(T, source) else @compileError("unsupported init parameter in plugin " ++ Plugin.id);
    }

    return @call(.never_inline, constructor, args);
}

pub fn close(comptime Plugin: type, instance: *Plugin, io: std.Io, closing: *lifecycle.Closing) void {
    if (!@hasDecl(Plugin, "close")) return;
    var args: std.meta.ArgsTuple(@TypeOf(Plugin.close)) = undefined;
    args[0] = instance;

    inline for (@typeInfo(@TypeOf(Plugin.close)).@"fn".param_types[1..], 1..) |parameter, argument| {
        args[argument] = if (parameter == std.Io) io else if (parameter == *lifecycle.Closing) closing else @compileError("unsupported close parameter in plugin " ++ Plugin.id);
    }

    @call(.never_inline, Plugin.close, args);
}

pub fn dependency(comptime name: []const u8, comptime T: type, instances: anytype, values: anytype, comptime before: usize) T {
    const Selections = @TypeOf(instances.*).selections;
    if (comptime provider(Selections, T)) |index| {
        const Provider = selectedPlugin(selectedType(Selections, index));
        if (index >= before) @compileError("dependency provider must appear earlier: " ++ Provider.id);
        const Contract = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
        return instances.get(Provider).provide(Contract);
    }
    if (comptime dependencyPlugin(T)) |Dependency| {
        if (comptime indexOfId(Selections, Dependency.id)) |index| {
            if (index >= before) @compileError("plugin dependency must appear earlier: " ++ Dependency.id);
            return instances.get(Dependency);
        }
    }
    return environmental(name, T, values);
}

pub fn Instances(comptime Selections: type) type {
    validate(Selections);
    const types = comptime pointerTypes(Selections);

    return struct {
        pub const selections = Selections;
        pointers: @Tuple(&types) = undefined,
        initialized: usize = 0,

        pub fn get(self: *const @This(), comptime Plugin: type) *Plugin {
            const index = comptime indexOfId(Selections, Plugin.id) orelse
                @compileError("plugin is not selected: " ++ Plugin.id);

            if (selectedPlugin(selectedType(Selections, index)) != Plugin)
                @compileError("selected plugin has a different type: " ++ Plugin.id);
            std.debug.assert(index < self.initialized);
            return self.pointers[index];
        }
    };
}

fn pointerTypes(comptime Selections: type) [selectedCount(Selections)]type {
    var types: [selectedCount(Selections)]type = undefined;

    for (0..types.len) |index| {
        const Plugin = selectedPlugin(selectedType(Selections, index));
        types[index] = *Plugin;
    }

    return types;
}

pub fn environment(base: anytype, extra: anytype) Environment(@TypeOf(base), @TypeOf(extra)) {
    var result: Environment(@TypeOf(base), @TypeOf(extra)) = undefined;
    const a = @typeInfo(@TypeOf(base)).@"struct";
    const b = @typeInfo(@TypeOf(extra)).@"struct";
    inline for (a.field_names, a.field_attrs) |name, attrs| if (!attrs.@"comptime") {
        @field(result, name) = @field(base, name);
    };
    inline for (b.field_names, b.field_attrs) |name, attrs| if (!attrs.@"comptime") {
        @field(result, name) = @field(extra, name);
    };
    return result;
}

fn Environment(comptime Base: type, comptime Extra: type) type {
    const a = @typeInfo(Base).@"struct";
    const b = @typeInfo(Extra).@"struct";
    const names = a.field_names ++ b.field_names;
    inline for (names, 0..) |name, index| {
        inline for (names[0..index]) |previous| if (std.mem.eql(u8, name, previous))
            @compileError("duplicate environment binding: " ++ name);
    }
    return @Struct(.auto, null, names, a.field_types ++ b.field_types, a.field_attrs ++ b.field_attrs);
}

pub fn configured(comptime Plugin: type, configuration: Plugin.Configuration) Selection(Plugin) {
    return .{ .configuration = configuration };
}

pub fn Selection(comptime Plugin: type) type {
    return struct {
        pub const plugin = Plugin;
        configuration: Plugin.Configuration,
    };
}

pub fn selectedCount(comptime Selections: type) usize {
    return (comptime tupleTypes(Selections)).len;
}

pub fn minimumTickScratchBytes(comptime Selections: type) usize {
    return comptime total: {
        var bytes: usize = 0;

        for (tupleTypes(Selections)) |field| {
            const Plugin = selectedPlugin(field);

            if (@hasDecl(Plugin, "tick_scratch_bytes")) bytes += Plugin.tick_scratch_bytes;
        }

        break :total bytes;
    };
}

pub fn closeTokenCount(comptime Selections: type) usize {
    var count: usize = 0;

    inline for (comptime tupleTypes(Selections)) |field| {
        const Plugin = selectedPlugin(field);

        if (@hasDecl(Plugin, "close")) count += 1;
    }

    return count;
}

pub fn selectedType(comptime Selections: type, comptime index: usize) type {
    const fields = comptime tupleTypes(Selections);

    if (index >= fields.len) @compileError("plugin selection index is out of bounds");
    return fields[index];
}

pub fn selectedPlugin(comptime Selected: type) type {
    if (!@hasDecl(Selected, "plugin"))
        @compileError("plugin selections must be made with plugin.configured");
    return Selected.plugin;
}

pub fn indexOfId(comptime Selections: type, comptime id: []const u8) ?usize {
    @setEvalBranchQuota(20_000_000);

    inline for (comptime tupleTypes(Selections), 0..) |field, index| {
        if (comptime std.mem.eql(u8, selectedPlugin(field).id, id)) return index;
    }

    return null;
}

pub fn compose(parts: anytype) Compose(@TypeOf(parts)) {
    const fields = comptime tupleTypes(@TypeOf(parts));
    var result: Compose(@TypeOf(parts)) = undefined;
    comptime var cursor: usize = 0;

    inline for (fields, 0..) |field, part_index| {
        const value = parts[part_index];

        if (comptime isSelection(field)) {
            result[cursor] = value;
            cursor += 1;
        } else {
            inline for (comptime tupleTypes(field), 0..) |_, nested_index| {
                result[cursor] = value[nested_index];
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

    inline for (comptime tupleTypes(@TypeOf(selections)), 0..) |field, index| {
        const id = selectedPlugin(field).id;

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
    const fields = comptime tupleTypes(Parts);
    comptime var count: usize = 0;

    inline for (fields) |field| count += partCount(field);
    comptime var result: [count]type = undefined;
    comptime var cursor: usize = 0;

    inline for (fields) |field| {
        if (isSelection(field)) {
            result[cursor] = field;
            cursor += 1;
        } else {
            inline for (tupleTypes(field)) |nested| {
                result[cursor] = nested;
                cursor += 1;
            }
        }
    }

    return @Tuple(&result);
}

pub fn Remove(comptime Selections: type, comptime Plugin: type) type {
    const fields = comptime tupleTypes(Selections);
    const removed = comptime indexOfPlugin(Selections, Plugin) orelse @compileError("plugin is not selected: " ++ Plugin.id);
    comptime var result: [fields.len - 1]type = undefined;

    inline for (0..removed) |index| result[index] = fields[index];

    inline for (removed + 1..fields.len) |index| result[index - 1] = fields[index];
    return @Tuple(&result);
}

pub fn Replace(comptime Selections: type, comptime Replacements: type) type {
    const fields = comptime tupleTypes(Selections);
    comptime validateReplacements(Selections, Replacements);
    comptime var result: [fields.len]type = undefined;

    inline for (fields, 0..) |field, index| {
        const id = selectedPlugin(field).id;
        result[index] = if (replacementIndex(Replacements, id)) |replacement|
            tupleTypes(Replacements)[replacement]
        else
            field;
    }

    return @Tuple(&result);
}

fn validateReplacements(comptime Selections: type, comptime Replacements: type) void {
    const fields = tupleTypes(Replacements);

    if (fields.len == 0) @compileError("plugin.replace requires at least one replacement");

    inline for (fields, 0..) |field, index| {
        if (!isSelection(field)) @compileError("plugin.replace accepts plugin selections");
        const Replacement = selectedPlugin(field);

        if (indexOfId(Selections, Replacement.id) == null)
            @compileError("cannot replace a plugin that is not selected: " ++ Replacement.id);

        inline for (fields[0..index]) |previous| {
            if (std.mem.eql(u8, Replacement.id, selectedPlugin(previous).id))
                @compileError("duplicate plugin replacement: " ++ Replacement.id);
        }
    }
}

fn replacementIndex(comptime Replacements: type, comptime id: []const u8) ?usize {
    inline for (tupleTypes(Replacements), 0..) |field, index|
        if (std.mem.eql(u8, id, selectedPlugin(field).id)) return index;
    return null;
}

pub fn InsertAfter(comptime Selections: type, comptime Anchor: type, comptime Inserted: type) type {
    const fields = comptime tupleTypes(Selections);
    const index = comptime indexOfPlugin(Selections, Anchor) orelse @compileError("plugin is not selected: " ++ Anchor.id);
    comptime var result: [fields.len + 1]type = undefined;

    inline for (0..index + 1) |source| result[source] = fields[source];
    result[index + 1] = Inserted;

    inline for (index + 1..fields.len) |source| result[source + 1] = fields[source];
    return @Tuple(&result);
}

fn indexOfPlugin(comptime Selections: type, comptime Plugin: type) ?usize {
    inline for (comptime tupleTypes(Selections), 0..) |field, index| {
        if (comptime selectedPlugin(field) == Plugin) return index;
    }

    return null;
}

pub fn validate(comptime Selections: type) void {
    const fields = comptime tupleTypes(Selections);
    @setEvalBranchQuota(1_000 + fields.len * fields.len * 32);

    inline for (fields, 0..) |field, index| {
        const Plugin = selectedPlugin(field);
        validatePlugin(Plugin);

        inline for (fields[0..index]) |previous| {
            if (comptime std.mem.eql(u8, Plugin.id, selectedPlugin(previous).id))
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
    validateInit(Plugin);
    validateLifecycle(Plugin);
}

fn validateDependenciesType(comptime Plugin: type) void {
    if (!@hasDecl(Plugin, "Dependencies")) return;

    if (@typeInfo(Plugin.Dependencies) != .@"struct")
        @compileError(Plugin.id ++ ".Dependencies must be a struct");

    inline for (@typeInfo(Plugin.Dependencies).@"struct".field_types) |field| {
        const Dependency = dependencyPlugin(field) orelse continue;

        if (@typeInfo(Dependency) != .@"struct" or !@hasDecl(Dependency, "id") or Dependency.id.len == 0)
            @compileError(Plugin.id ++ " dependency must point to a plugin struct with an id");
    }
}

fn validateInit(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.init)).@"fn";
    var seen: u8 = 0;

    for (info.param_types) |parameter| {
        const T = parameter orelse @compileError(Plugin.id ++ ".init requires typed parameters");
        const bit: u8 = if (T == std.mem.Allocator) 1 else if (T == std.Io) 2 else if (T == Plugin.Configuration) 4 else if (@hasDecl(Plugin, "Dependencies") and T == Plugin.Dependencies) 8 else if (@hasDecl(Plugin, "Meta") and T == Plugin.Meta) 16 else @compileError(Plugin.id ++ ".init has an unsupported parameter");

        if (seen & bit != 0) @compileError(Plugin.id ++ ".init has a duplicate injected parameter");
        seen |= bit;
    }

    const result = info.return_type orelse @compileError(Plugin.id ++ ".init must return !*Self");
    if (@typeInfo(result) != .error_union or @typeInfo(result).error_union.payload != *Plugin)
        @compileError(Plugin.id ++ ".init must return !*Self");
}

fn validateLifecycle(comptime Plugin: type) void {
    if (@hasDecl(Plugin, "tick")) validateTick(Plugin);

    if (@hasDecl(Plugin, "checkpoint")) validateCheckpoint(Plugin);

    if (@hasDecl(Plugin, "close")) validateClose(Plugin);

    if (@hasDecl(Plugin, "beginTick")) validateBoundary(Plugin, "beginTick", false);
    if (@hasDecl(Plugin, "endTick")) validateBoundary(Plugin, "endTick", true);
    if (@hasDecl(Plugin, "publish")) validateBoundary(Plugin, "publish", false);
}

fn validateBoundary(comptime Plugin: type, comptime name: []const u8, comptime success: bool) void {
    const info = @typeInfo(@TypeOf(@field(Plugin, name))).@"fn";
    if (info.param_types.len != (if (success) @as(usize, 2) else 1) or info.param_types[0] != *Plugin or info.return_type != void)
        @compileError(Plugin.id ++ "." ++ name ++ " has an invalid lifecycle signature");
    if (success and info.param_types[1] != bool) @compileError(Plugin.id ++ ".endTick requires a success bool");
}

fn validateTick(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.tick)).@"fn";
    const result = info.return_type orelse @compileError(Plugin.id ++ ".tick requires an explicit return type");
    if (result != void and (@typeInfo(result) != .error_union or @typeInfo(result).error_union.payload != void))
        @compileError(Plugin.id ++ ".tick must return void or !void");

    if (info.param_types.len < 1 or info.param_types.len > 4 or info.param_types[0] != *Plugin)
        @compileError(Plugin.id ++ ".tick must take *Self and optional Allocator, std.Io, storage.Space");
    var seen: u8 = 0;

    for (info.param_types[1..]) |parameter| {
        const bit: u8 = if (parameter == std.mem.Allocator) 1 else if (parameter == std.Io) 2 else if (parameter == storage.Space) 4 else @compileError(Plugin.id ++ ".tick accepts only Allocator, std.Io and storage.Space after *Self");

        if (seen & bit != 0) @compileError(Plugin.id ++ ".tick has a duplicate injected parameter");
        seen |= bit;
    }
}

fn validateCheckpoint(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.checkpoint)).@"fn";
    const result = info.return_type orelse
        @compileError(Plugin.id ++ ".checkpoint must return !void");

    if (info.param_types.len < 2 or info.param_types.len > 4 or info.param_types[0] != *Plugin or
        @typeInfo(result) != .error_union or
        @typeInfo(result).error_union.payload != void)
        @compileError(Plugin.id ++ ".checkpoint requires *Self, storage.Space, optional Allocator and std.Io, and an error union void result");
    var seen: u8 = 0;

    for (info.param_types[1..]) |parameter| {
        const bit: u8 = if (parameter == storage.Space) 1 else if (parameter == std.Io) 2 else if (parameter == std.mem.Allocator) 4 else @compileError(Plugin.id ++ ".checkpoint accepts only storage.Space, std.Io and Allocator after *Self");

        if (seen & bit != 0) @compileError(Plugin.id ++ ".checkpoint has a duplicate injected parameter");
        seen |= bit;
    }

    if (seen & 1 == 0) @compileError(Plugin.id ++ ".checkpoint requires storage.Space");
}

fn validateClose(comptime Plugin: type) void {
    const info = @typeInfo(@TypeOf(Plugin.close)).@"fn";

    if (info.param_types.len < 2 or info.param_types.len > 3 or info.param_types[0] != *Plugin or info.return_type != void)
        @compileError(Plugin.id ++ ".close requires *Self, *Closing, optional std.Io and a void result");
    var seen: u8 = 0;

    for (info.param_types[1..]) |parameter| {
        const bit: u8 = if (parameter == *lifecycle.Closing) 1 else if (parameter == std.Io) 2 else @compileError(Plugin.id ++ ".close accepts only *Closing and std.Io after *Self");

        if (seen & bit != 0) @compileError(Plugin.id ++ ".close has a duplicate injected parameter");
        seen |= bit;
    }

    if (seen & 1 == 0) @compileError(Plugin.id ++ ".close requires *Closing");
}

fn validateDependencies(comptime Selections: type, comptime Plugin: type, comptime plugin_index: usize) void {
    const info = @typeInfo(dependenciesType(Plugin)).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime provider(Selections, T)) |index| {
            if (index >= plugin_index) @compileError("dependency provider must appear before " ++ Plugin.id ++ "." ++ name);
            continue;
        }
        const Dependency = dependencyPlugin(T) orelse continue;
        const found = comptime indexOfId(Selections, Dependency.id);

        if (found) |index| if (index >= plugin_index)
            @compileError("plugin dependencies must appear earlier: '" ++ Plugin.id ++ "' -> '" ++ Dependency.id ++ "'");
    }
}

/// Providers declare `Provides = .{Contract}` and return it from `provide(self, Contract)`.
/// The dependency keeps its concrete contract type. No erased pointer crosses this boundary.
pub fn provider(comptime Selections: type, comptime T: type) ?usize {
    const Required = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    var found: ?usize = null;
    inline for (comptime tupleTypes(Selections), 0..) |field, index| {
        const Provider = selectedPlugin(field);
        if (!@hasDecl(Provider, "Provides")) continue;
        inline for (Provider.Provides) |Contract| {
            if (Contract != Required) continue;
            if (found != null) @compileError("multiple providers for contract " ++ @typeName(Required));
            if (!@hasDecl(Provider, "provide")) @compileError(Provider.id ++ " declares Provides without provide()");
            found = index;
        }
    }
    return found;
}

pub fn dependenciesType(comptime Plugin: type) type {
    return if (@hasDecl(Plugin, "Dependencies")) Plugin.Dependencies else struct {};
}

pub fn dependencyPlugin(comptime T: type) ?type {
    const Required = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    return switch (@typeInfo(Required)) {
        .pointer => |pointer| if (pointer.size == .one and isPlugin(pointer.child)) pointer.child else null,
        else => null,
    };
}

fn isPlugin(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "id");
}

fn partCount(comptime Part: type) usize {
    if (isSelection(Part)) return 1;
    return tupleTypes(Part).len;
}

fn isSelection(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "plugin");
}

fn tupleTypes(comptime Selections: type) []const type {
    const info = @typeInfo(Selections);

    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("plugin selections must be a tuple");
    return info.@"struct".field_types;
}
pub fn environmental(comptime name: []const u8, comptime T: type, values: anytype) T {
    if (@hasField(@TypeOf(values), name)) {
        return @field(values, name);
    }

    const Child = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    if (@typeInfo(Child) != .pointer or @typeInfo(Child).pointer.size != .one) {
        if (@typeInfo(T) == .optional) return null;
        @compileError("missing named environment dependency: " ++ name);
    }

    comptime var match: ?[]const u8 = null;

    const info = @typeInfo(@TypeOf(values)).@"struct";
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (comptime !compatible(T, Field)) continue;

        if (match != null) @compileError("ambiguous environment dependency: " ++ name);
        match = field_name;
    }

    if (match) |field| return @field(values, field);
    if (@typeInfo(T) == .optional) return null;
    @compileError("missing environment dependency: " ++ name);
}

fn compatible(comptime Expected: type, comptime Actual: type) bool {
    return Expected == Actual or (@typeInfo(Expected) == .optional and @typeInfo(Expected).optional.child == Actual);
}

pub fn metadata(comptime T: type, source: anytype) T {
    var result: T = undefined;

    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        if (@hasField(@TypeOf(source), name)) {
            @field(result, name) = @field(source, name);
        } else if (@typeInfo(Field) == .optional) {
            @field(result, name) = null;
        } else {
            @compileError("missing required plugin metadata: " ++ name);
        }
    }

    return result;
}
