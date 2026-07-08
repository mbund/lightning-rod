const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input_path = args.next() orelse return error.NotEnoughArgs;
    const output_path = args.next() orelse return error.NotEnoughArgs;
    const output_file = try std.Io.Dir.createFile(.cwd(), init.io, output_path, .{});
    defer output_file.close(init.io);

    const json = try readJson(
        init.io,
        allocator,
        input_path,
    );
    defer json.deinit();

    const protocol = try Protocol.fromJson(allocator, json.value);
    const buffer = try allocator.alloc(u8, 4096);
    var output_writer = output_file.writer(init.io, buffer);
    var writer = IndentedWriter{ .writer = &output_writer.interface, .allocator = allocator };
    try protocol.codegen(allocator, &writer);
    try output_writer.interface.flush();
}

const Protocol = struct {
    types: Types,
    handshaking: State,
    status: State,
    login: State,
    play: State,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !Protocol {
        const object = try expectObject(json);
        const types = try Types.fromJson(allocator, try expectGet(object, "types"));
        const handshaking = try State.fromJson(allocator, try expectGet(object, "handshaking"));
        const status = try State.fromJson(allocator, try expectGet(object, "status"));
        const login = try State.fromJson(allocator, try expectGet(object, "login"));
        const play = try State.fromJson(allocator, try expectGet(object, "play"));

        return Protocol{
            .types = types,
            .handshaking = handshaking,
            .status = status,
            .login = login,
            .play = play,
        };
    }

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter) !void {
        try writer.println("const std = @import(\"std\");", .{});
        try writer.println("const protocol_support = @import(\"protocol_support\");\n", .{});
        try self.types.codegen(allocator, writer, .{ .outer = &self.types, .inner = null });
        try writer.println("", .{});
        try self.handshaking.codegen(allocator, writer, "handshaking", &self.types);
        try self.status.codegen(allocator, writer, "status", &self.types);
        try self.login.codegen(allocator, writer, "login", &self.types);
        try self.play.codegen(allocator, writer, "play", &self.types);
        try writer.println("", .{});
    }
};

const Types = struct {
    allocator: std.mem.Allocator,
    types: std.StringHashMap(Type),

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !Types {
        const object = try expectObject(json);
        var types = std.StringHashMap(Type).init(allocator);

        var it = object.iterator();
        while (it.next()) |entry| {
            try types.put(entry.key_ptr.*, try Type.fromJson(allocator, entry.key_ptr.*, entry.value_ptr.*));
        }

        return Types{
            .allocator = allocator,
            .types = types,
        };
    }

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope) !void {
        var it = self.types.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "packet")) {
                continue;
            }
            const resolved = try entry.value_ptr.resolve(allocator, scope, null);
            var cursors = try Cursors.init(allocator);
            try cursors.pushName("packet");
            const cursorTree = try resolved.cursor(&cursors);
            try writer.println("pub fn read(buffer: []const u8) {s} {{", .{cursorTree.head.name});
            writer.indent();
            try writer.println("return .{{ .buffer = buffer }};", .{});
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
            try cursorTree.head.codegen(writer);
            try writer.println("pub fn write(buffer: []u8) write__{s} {{", .{cursorTree.head.name});
            writer.indent();
            try writer.println("return .{{ .buffer = buffer, .rest = buffer }};", .{});
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
            try cursorTree.head.codegenWrite(writer);
        }
    }

    pub fn codegenEnvelope(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope) !void {
        const packet = self.types.get("packet") orelse return;
        const container = switch (packet) {
            .container => |container| container,
            else => return,
        };
        if (container.fields.len == 0) return;
        const mapper = switch (container.fields[0].type) {
            .mapper => |mapper| mapper,
            else => return,
        };
        const packet_switch = if (container.fields.len > 1) switch (container.fields[1].type) {
            .switch_ => |switch_| switch_,
            else => null,
        } else null;

        try self.codegenNamedViewTypes(allocator, writer, scope);
        try self.codegenNamedWriteTypes(allocator, writer, scope);

        try writer.println("pub fn read(buffer: []const u8) packet {{", .{});
        writer.indent();
        try writer.println("return .{{ .buffer = buffer }};", .{});
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});

        try writer.println("pub const packet = struct {{", .{});
        writer.indent();
        try writer.println("buffer: []const u8,", .{});
        try writer.println("", .{});
        try writer.println("pub fn name(self: @This()) protocol_support.ReadError!union(enum) {{", .{});
        writer.indent();
        for (mapper.mappings) |mapping| {
            try writer.println("{s}: body__{f},", .{ mapping.name, idfmt(packetBodyTypeName(packet_switch, mapping.name)) });
        }
        try writer.println("default: protocol_support.RawPayload,", .{});
        writer.unindent();
        try writer.println("}} {{", .{});
        writer.indent();
        try writer.println("const value, const rest = try protocol_support.read_{s}(self.buffer);", .{@tagName(mapper.type)});
        try writer.println("return switch (value) {{", .{});
        writer.indent();
        for (mapper.mappings) |mapping| {
            try writer.println("{} => .{{ .{s} = .{{ .buffer = rest }} }},", .{ mapping.value, mapping.name });
        }
        try writer.println("else => .{{ .default = .{{ .buffer = rest }} }},", .{});
        writer.unindent();
        try writer.println("}};", .{});
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        if (packet_switch) |switch_| {
            for (switch_.fields) |field| {
                try self.codegenPacketBodyCursor(allocator, writer, scope, field);
            }
        }

        try self.codegenEnvelopeWriter(allocator, writer, scope, mapper, packet_switch);
    }

    fn codegenPacketBodyCursor(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope, packet_field: Field) !void {
        const body_name = try std.fmt.allocPrint(allocator, "body__{f}", .{idfmt(packet_field.name)});
        defer allocator.free(body_name);
        const container = switch (packet_field.type.resolveAstWriteAlias(self, scope).*) {
            .container => |container| container,
            else => {
                const fields = [_]Field{packet_field};
                try codegenAstReadCursorTypes(self, writer, scope, body_name, &fields, &.{}, 0);
                return;
            },
        };

        if (container.fields.len == 0) {
            try writer.println("pub const {s} = protocol_support.FinalCursor;", .{body_name});
            try writer.println("", .{});
            return;
        }

        try codegenAstReadCursorTypes(self, writer, scope, body_name, container.fields, &.{}, 0);
    }

    fn codegenEnvelopeWriter(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope, mapper: anytype, packet_switch: ?SwitchType) !void {
        try writer.println("pub fn write(buffer: []u8) write_packet {{", .{});
        writer.indent();
        try writer.println("return .{{ .buffer = buffer, .rest = buffer }};", .{});
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});

        try writer.println("pub const write_packet = struct {{", .{});
        writer.indent();
        try writer.println("buffer: []u8,", .{});
        try writer.println("rest: []u8,", .{});
        try writer.println("", .{});
        for (mapper.mappings) |mapping| {
            try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!write__body__{f} {{", .{ idfmt(mapping.name), idfmt(packetBodyTypeName(packet_switch, mapping.name)) });
            writer.indent();
            try writer.println("var rest = self.rest;", .{});
            try writer.println("rest = try protocol_support.write_{s}(rest, {});", .{ @tagName(mapper.type), mapping.value });
            try writer.println("return .{{ .buffer = self.buffer, .rest = rest }};", .{});
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
        }
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        if (packet_switch) |switch_| {
            for (switch_.fields) |field| {
                const body_name = try std.fmt.allocPrint(allocator, "write__body__{f}", .{idfmt(field.name)});
                defer allocator.free(body_name);
                try field.type.codegenAstWriteType(self, writer, scope, body_name, "protocol_support.FinalWriteCursor", .normal, 0);
            }
        }
    }

    fn codegenNamedWriteTypes(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope) !void {
        _ = self;
        if (scope.inner) |inner| {
            try codegenNamedWriteTypesFromMap(allocator, writer, scope, inner);
        }
        try codegenNamedWriteTypesFromMap(allocator, writer, scope, scope.outer);
    }

    fn codegenNamedViewTypes(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope) !void {
        _ = self;
        if (scope.inner) |inner| {
            try codegenNamedViewTypesFromMap(allocator, writer, scope, inner);
        }
        try codegenNamedViewTypesFromMap(allocator, writer, scope, scope.outer);
    }

    fn codegenNamedViewTypesFromMap(allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope, types: *const Types) !void {
        var it = types.types.iterator();
        while (it.next()) |entry| {
            if (!isNamedWriteTarget(entry.key_ptr.*)) continue;
            const skip_name = try namedSkipFunctionName(allocator, entry.key_ptr.*);
            defer allocator.free(skip_name);
            try writer.println("fn {s}(buffer: []const u8) protocol_support.ReadError![]const u8 {{", .{skip_name});
            writer.indent();
            try writer.println("var rest = buffer;", .{});
            try entry.value_ptr.codegenAstSkip(types, writer, scope, "rest");
            try writer.println("return rest;", .{});
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});

            const type_name = try namedViewTypeName(allocator, entry.key_ptr.*);
            defer allocator.free(type_name);
            try entry.value_ptr.codegenAstViewType(types, writer, scope, type_name, 0);
        }
    }

    fn codegenNamedWriteTypesFromMap(allocator: std.mem.Allocator, writer: *IndentedWriter, scope: Scope, types: *const Types) !void {
        var it = types.types.iterator();
        while (it.next()) |entry| {
            if (!isNamedWriteTarget(entry.key_ptr.*)) continue;
            const function_name = try namedWriteFunctionName(allocator, entry.key_ptr.*);
            defer allocator.free(function_name);
            try writer.println("pub fn {s}(comptime Cont: type) type {{", .{function_name});
            writer.indent();
            try writer.println("return struct {{", .{});
            writer.indent();
            const root_name = try std.fmt.allocPrint(allocator, "{s}__root", .{function_name});
            defer allocator.free(root_name);
            try entry.value_ptr.codegenAstWriteType(types, writer, scope, root_name, "Cont.Next", .normal_cont, 0);
            writer.unindent();
            try writer.println("}}.{s};", .{root_name});
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
        }
    }
};

fn packetBodyTypeName(packet_switch: ?SwitchType, packet_name: []const u8) []const u8 {
    if (packet_switch) |switch_| {
        for (switch_.fields) |field| {
            if (std.mem.eql(u8, field.name, packet_name)) return field.name;
        }
    }
    return "protocol_support.RawPayload";
}

fn astReadCursorTypeName(allocator: std.mem.Allocator, body_name: []const u8, fields: []const Field, index: usize) ![]const u8 {
    if (index == 0) return allocator.dupe(u8, body_name);
    const sanitized = try sanitizeTypeNamePart(allocator, fields[index].name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "{s}__{s}", .{ body_name, sanitized });
}

fn codegenAstReadCursorTypes(types: *const Types, writer: *IndentedWriter, scope: Scope, body_name: []const u8, fields: []const Field, carried_bindings: []const CompareBinding, index: usize) anyerror!void {
    const cursor_name = try astReadCursorTypeName(writer.allocator, body_name, fields, index);
    defer writer.allocator.free(cursor_name);
    const field = fields[index];
    const has_next = index + 1 < fields.len;
    const next_name = if (has_next)
        try astReadCursorTypeName(writer.allocator, body_name, fields, index + 1)
    else
        try writer.allocator.dupe(u8, "protocol_support.FinalCursor");
    defer writer.allocator.free(next_name);

    const carries_current = (fieldFeedsLaterSwitch(fields, index) or fieldFeedsLaterFieldCountArray(fields, index) or fieldFeedsLaterView(fields, index, types, scope)) and field.type.canAstReadCompareValue(types, scope);

    var next_bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, if (has_next) carried_bindings.len + @intFromBool(carries_current) else 0);
    defer next_bindings.deinit(writer.allocator);
    if (has_next) try next_bindings.appendSlice(writer.allocator, carried_bindings);

    const current_compare_name = if (carries_current) try std.fmt.allocPrint(writer.allocator, "field_compare_{}", .{writer.nextId()}) else "";
    defer if (carries_current) writer.allocator.free(current_compare_name);
    if (has_next and carries_current) {
        removeCompareBindingsByName(&next_bindings, field.name);
        try next_bindings.append(writer.allocator, .{
            .name = field.name,
            .type = &fields[index].type,
            .value_name = current_compare_name,
        });
    }

    try writer.println("pub const {s} = struct {{", .{cursor_name});
    writer.indent();
    try writer.println("buffer: []const u8,", .{});
    for (carried_bindings) |binding| {
        const storage_name = try compareBindingFieldName(writer.allocator, binding.name);
        defer writer.allocator.free(storage_name);
        try writer.println("{s}: {s},", .{ storage_name, try compareBindingStorageType(binding, types, scope) });
    }
    try writer.println("", .{});
    switch (field.type.resolveAstWriteAlias(types, scope).*) {
        .bitfield => |bitfield| {
            try writer.println("pub const Value = {s};", .{try codegenBitfieldValueType(writer.allocator, bitfield.fields)});
            try writer.println("", .{});
        },
        .bitflags => |bitflags| {
            try writer.println("pub const Value = {s};", .{try codegenBitflagsValueType(writer.allocator, bitflags.flags)});
            try writer.println("", .{});
        },
        else => {},
    }

    try codegenAstReadCursorMethod(types, writer, scope, cursor_name, field, next_name, carried_bindings, next_bindings.items, current_compare_name, carries_current);

    writer.unindent();
    try writer.println("}};", .{});
    try writer.println("", .{});

    const field_return_type = try field.type.codegenAstReturnType(types, scope, cursor_name, field.name, 0);
    defer if (std.mem.startsWith(u8, field_return_type, "view")) types.allocator.free(field_return_type);
    if (std.mem.startsWith(u8, field_return_type, "view") and !field.type.isNamedWriteReference()) {
        const view_name = try astViewTypeName(types.allocator, cursor_name, field.name, 0);
        defer types.allocator.free(view_name);
        const view_bindings = try filterBindingsForType(writer.allocator, &field.type, types, scope, carried_bindings);
        defer writer.allocator.free(view_bindings);
        try field.type.codegenAstViewTypeWithCompares(types, writer, scope, view_name, view_bindings, 1);
    }

    if (index + 1 < fields.len) {
        try codegenAstReadCursorTypes(types, writer, scope, body_name, fields, next_bindings.items, index + 1);
    }
}

fn codegenAstContainerReadCursorEntry(types: *const Types, writer: *IndentedWriter, scope: Scope, cursor_name: []const u8, fields: []const Field, carried_bindings: []const CompareBinding) anyerror!void {
    if (fields.len == 0) return;

    const field = fields[0];
    const has_next = fields.len > 1;
    const next_name = if (has_next)
        try astReadCursorTypeName(writer.allocator, cursor_name, fields, 1)
    else
        try writer.allocator.dupe(u8, "protocol_support.FinalCursor");
    defer writer.allocator.free(next_name);

    const carries_current = (fieldFeedsLaterSwitch(fields, 0) or fieldFeedsLaterFieldCountArray(fields, 0) or fieldFeedsLaterView(fields, 0, types, scope)) and field.type.canAstReadCompareValue(types, scope);

    var next_bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, if (has_next) carried_bindings.len + @intFromBool(carries_current) else 0);
    defer next_bindings.deinit(writer.allocator);
    if (has_next) try next_bindings.appendSlice(writer.allocator, carried_bindings);

    const current_compare_name = if (carries_current) try std.fmt.allocPrint(writer.allocator, "field_compare_{}", .{writer.nextId()}) else "";
    defer if (carries_current) writer.allocator.free(current_compare_name);
    if (has_next and carries_current) {
        removeCompareBindingsByName(&next_bindings, field.name);
        try next_bindings.append(writer.allocator, .{
            .name = field.name,
            .type = &fields[0].type,
            .value_name = current_compare_name,
        });
    }

    switch (field.type.resolveAstWriteAlias(types, scope).*) {
        .bitfield => |bitfield| {
            try writer.println("pub const Value = {s};", .{try codegenBitfieldValueType(writer.allocator, bitfield.fields)});
            try writer.println("", .{});
        },
        .bitflags => |bitflags| {
            try writer.println("pub const Value = {s};", .{try codegenBitflagsValueType(writer.allocator, bitflags.flags)});
            try writer.println("", .{});
        },
        else => {},
    }

    try codegenAstReadCursorMethod(types, writer, scope, cursor_name, field, next_name, carried_bindings, next_bindings.items, current_compare_name, carries_current);
}

fn codegenAstContainerReadCursorTailTypes(types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, fields: []const Field, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
    if (fields.len == 0) return;

    const field = fields[0];
    const field_return_type = try field.type.codegenAstReturnType(types, scope, type_name, field.name, 0);
    defer if (std.mem.startsWith(u8, field_return_type, "view")) types.allocator.free(field_return_type);
    if (std.mem.startsWith(u8, field_return_type, "view") and !field.type.isNamedWriteReference()) {
        const view_name = try astViewTypeName(types.allocator, type_name, field.name, 0);
        defer types.allocator.free(view_name);
        const view_bindings = try filterBindingsForType(writer.allocator, &field.type, types, scope, carried_bindings);
        defer writer.allocator.free(view_bindings);
        try field.type.codegenAstViewTypeWithCompares(types, writer, scope, view_name, view_bindings, depth + 1);
    }

    if (fields.len > 1) {
        const carries_current = (fieldFeedsLaterSwitch(fields, 0) or fieldFeedsLaterFieldCountArray(fields, 0) or fieldFeedsLaterView(fields, 0, types, scope)) and field.type.canAstReadCompareValue(types, scope);
        var next_bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, carried_bindings.len + @intFromBool(carries_current));
        defer next_bindings.deinit(writer.allocator);
        try next_bindings.appendSlice(writer.allocator, carried_bindings);
        if (carries_current) {
            removeCompareBindingsByName(&next_bindings, field.name);
            try next_bindings.append(writer.allocator, .{
                .name = field.name,
                .type = &fields[0].type,
                .value_name = "",
            });
        }
        try codegenAstReadCursorTypes(types, writer, scope, type_name, fields, next_bindings.items, 1);
    }
}

fn codegenAstReadCursorMethod(
    types: *const Types,
    writer: *IndentedWriter,
    scope: Scope,
    cursor_name: []const u8,
    field: Field,
    next_name: []const u8,
    carried_bindings: []const CompareBinding,
    next_bindings: []const CompareBinding,
    current_compare_name: []const u8,
    carries_current: bool,
) anyerror!void {
    const actual = field.type.resolveAstWriteAlias(types, scope);
    const return_type = switch (actual.*) {
        .bitfield, .bitflags => try writer.allocator.dupe(u8, "Value"),
        else => try field.type.codegenAstReturnType(types, scope, cursor_name, field.name, 0),
    };
    defer if (std.mem.startsWith(u8, return_type, "view") or std.mem.eql(u8, return_type, "Value")) types.allocator.free(return_type);

    try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!struct {{ {s}, {s} }} {{", .{ idfmt(field.name), return_type, next_name });
    writer.indent();
    if (actual.* == .native and actual.native == .void) {
        try writer.println("const rest = self.buffer;", .{});
    } else {
        try writer.println("var rest = self.buffer;", .{});
    }

    var method_bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, carried_bindings.len);
    defer {
        for (method_bindings.items) |binding| writer.allocator.free(binding.value_name);
        method_bindings.deinit(writer.allocator);
    }
    for (carried_bindings) |binding| {
        const storage_name = try compareBindingFieldName(writer.allocator, binding.name);
        defer writer.allocator.free(storage_name);
        const value_name = try std.fmt.allocPrint(writer.allocator, "self.{s}", .{storage_name});
        try method_bindings.append(writer.allocator, .{ .name = binding.name, .type = binding.type, .value_name = value_name });
    }

    if (field.type.codegenAstIsScalar(types, scope)) {
        try codegenAstReadScalarInto(types, writer, scope, &field.type, "rest", "field_value");
        if (carries_current) {
            try writer.println("const {s} = field_value;", .{current_compare_name});
        }
    } else {
        try writer.println("const field_start = rest;", .{});
        if (carries_current) {
            try field.type.codegenAstReadCompareValue(types, writer, scope, "rest", current_compare_name, field.name, method_bindings.items, 12);
        } else {
            try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", method_bindings.items, 12);
        }
        const child_bindings = try filterBindingsForType(writer.allocator, &field.type, types, scope, method_bindings.items);
        defer writer.allocator.free(child_bindings);
        const remaining_expr = try field.type.codegenAstRemainingExpr(types, scope, writer.allocator, method_bindings.items);
        defer if (remaining_expr) |expr| writer.allocator.free(expr);
        try printReadViewValueInitializer(writer, "field_value", return_type, "protocol_support.slice_to_rest(field_start, rest)", remaining_expr, child_bindings);
    }

    try printReadCursorReturn(writer, "field_value", "rest", carried_bindings, next_bindings, carries_current);
    writer.unindent();
    try writer.println("}}", .{});
}

fn printReadViewValueInitializer(writer: *IndentedWriter, value_name: []const u8, value_type: []const u8, buffer_expr: []const u8, remaining_expr: ?[]const u8, bindings: []const CompareBinding) !void {
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("const {s}: {s} = .{{ .buffer = {s}", .{ value_name, value_type, buffer_expr });
    if (remaining_expr) |remaining| {
        try writer.writer.print(", .remaining = {s}", .{remaining});
    }
    for (bindings) |binding| {
        const field_name = try compareBindingFieldName(writer.allocator, binding.name);
        defer writer.allocator.free(field_name);
        try writer.writer.print(", .{s} = {s}", .{ field_name, binding.value_name });
    }
    try writer.writer.print(" }};\n", .{});
}

fn printReadCursorReturn(writer: *IndentedWriter, value_name: []const u8, rest_name: []const u8, carried_bindings: []const CompareBinding, next_bindings: []const CompareBinding, carries_current: bool) !void {
    _ = carried_bindings;
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("return .{{ {s}, .{{ .buffer = {s}", .{ value_name, rest_name });
    for (0.., next_bindings) |i, binding| {
        const field_name = try compareBindingFieldName(writer.allocator, binding.name);
        defer writer.allocator.free(field_name);
        if (carries_current and i + 1 == next_bindings.len) {
            try writer.writer.print(", .{s} = {s}", .{ field_name, binding.value_name });
        } else {
            try writer.writer.print(", .{s} = self.{s}", .{ field_name, field_name });
        }
    }
    try writer.writer.print(" }} }};\n", .{});
}

const State = struct {
    toServer: Types,
    toClient: Types,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !State {
        return .{
            .toServer = try Types.fromJson(allocator, try expectGet(try expectObject(try expectGet(try expectObject(json), "toServer")), "types")),
            .toClient = try Types.fromJson(allocator, try expectGet(try expectObject(try expectGet(try expectObject(json), "toClient")), "types")),
        };
    }

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, name: []const u8, outer: *const Types) !void {
        try writer.println("pub const {s} = struct {{", .{name});
        writer.indent();

        try writer.println("pub const toServer = struct {{", .{});
        writer.indent();
        try self.toServer.codegenEnvelope(allocator, writer, .{ .outer = outer, .inner = &self.toServer });
        writer.unindent();
        try writer.println("}};", .{});

        try writer.println("pub const toClient = struct {{", .{});
        writer.indent();
        try self.toClient.codegenEnvelope(allocator, writer, .{ .outer = outer, .inner = &self.toClient });
        writer.unindent();
        try writer.println("}};", .{});
        writer.unindent();
        try writer.println("}};\n", .{});
    }
};

const Scope = struct {
    outer: *const Types,
    inner: ?*const Types,
};

const NativeType = enum {
    varint,
    varlong,
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    bool,
    f32,
    f64,
    UUID,
    option,
    entityMetadataLoop,
    topBitSetTerminatedArray,
    bitfield,
    bitflags,
    void,
    restBuffer,
    nbt,
    optionalNbt,
    anonymousNbt,
    anonOptionalNbt,
    registryEntryHolder,
    registryEntryHolderSet,
    fake,

    pub fn fromString(str: []const u8) !NativeType {
        if (std.mem.eql(u8, str, "varint")) {
            return .varint;
        }
        if (std.mem.eql(u8, str, "varlong")) {
            return .varlong;
        }
        if (std.mem.eql(u8, str, "pstring")) {
            return .fake;
        }
        if (std.mem.eql(u8, str, "buffer")) {
            return .fake;
        }
        if (std.mem.eql(u8, str, "u8")) {
            return .u8;
        }
        if (std.mem.eql(u8, str, "u16")) {
            return .u16;
        }
        if (std.mem.eql(u8, str, "u32")) {
            return .u32;
        }
        if (std.mem.eql(u8, str, "u64")) {
            return .u64;
        }
        if (std.mem.eql(u8, str, "i8")) {
            return .i8;
        }
        if (std.mem.eql(u8, str, "i16")) {
            return .i16;
        }
        if (std.mem.eql(u8, str, "i32")) {
            return .i32;
        }
        if (std.mem.eql(u8, str, "i64")) {
            return .i64;
        }
        if (std.mem.eql(u8, str, "bool")) {
            return .bool;
        }
        if (std.mem.eql(u8, str, "f32")) {
            return .f32;
        }
        if (std.mem.eql(u8, str, "f64")) {
            return .f64;
        }
        if (std.mem.eql(u8, str, "UUID")) {
            return .UUID;
        }
        if (std.mem.eql(u8, str, "option")) {
            return .option;
        }
        if (std.mem.eql(u8, str, "entityMetadataLoop")) {
            return .entityMetadataLoop;
        }
        if (std.mem.eql(u8, str, "topBitSetTerminatedArray")) {
            return .topBitSetTerminatedArray;
        }
        if (std.mem.eql(u8, str, "bitflags")) {
            return .bitflags;
        }
        if (std.mem.eql(u8, str, "void")) {
            return .void;
        }
        if (std.mem.eql(u8, str, "restBuffer")) {
            return .restBuffer;
        }
        if (std.mem.eql(u8, str, "nbt")) {
            return .nbt;
        }
        if (std.mem.eql(u8, str, "optionalNbt")) {
            return .optionalNbt;
        }
        if (std.mem.eql(u8, str, "anonymousNbt")) {
            return .anonymousNbt;
        }
        if (std.mem.eql(u8, str, "anonOptionalNbt")) {
            return .anonOptionalNbt;
        }
        if (std.mem.eql(u8, str, "registryEntryHolder")) {
            return .registryEntryHolder;
        }
        if (std.mem.eql(u8, str, "registryEntryHolderSet")) {
            return .registryEntryHolderSet;
        }
        if (std.mem.eql(u8, str, "bitfield")) {
            return .fake;
        }
        if (std.mem.eql(u8, str, "switch")) {
            return .fake;
        }
        if (std.mem.eql(u8, str, "container")) {
            return .fake;
        }
        if (std.mem.eql(u8, str, "array")) {
            return .fake;
        }
        std.debug.print("Unknown native type: {s}\n", .{str});
        return error.UnknownNativeType;
    }

    fn codegenType(self: NativeType) ![]const u8 {
        return switch (self) {
            .varint => "i32",
            .varlong => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .bool => "bool",
            .f32 => "f32",
            .f64 => "f64",
            .UUID => "protocol_support.UUID",
            .option => "protocol_support.option",
            .entityMetadataLoop => "protocol_support.entityMetadataLoop",
            .topBitSetTerminatedArray => "protocol_support.topBitSetTerminatedArray",
            .bitfield => "protocol_support.bitfield",
            .bitflags => "protocol_support.bitflags",
            .void => "protocol_support.void",
            .restBuffer => "protocol_support.restBuffer",
            .nbt => "protocol_support.nbt",
            .optionalNbt => "protocol_support.optionalNbt",
            .anonymousNbt => "protocol_support.anonymousNbt",
            .anonOptionalNbt => "protocol_support.anonOptionalNbt",
            .registryEntryHolder => "protocol_support.registryEntryHolder",
            .registryEntryHolderSet => "protocol_support.registryEntryHolderSet",
            .fake => error.ReferencedFakeNativeType,
        };
    }

    fn hasDirectWrite(self: NativeType) bool {
        return switch (self) {
            .varint,
            .varlong,
            .u8,
            .u16,
            .u32,
            .u64,
            .i8,
            .i16,
            .i32,
            .i64,
            .bool,
            .f32,
            .f64,
            .UUID,
            .void,
            .restBuffer,
            .nbt,
            .optionalNbt,
            .anonymousNbt,
            .anonOptionalNbt,
            => true,
            else => false,
        };
    }
};

const Field = struct {
    name: []const u8,
    type: Type,
};

const IndirectField = struct {
    name: []const u8,
    type: *Type,
};

const BitfieldType = struct {
    size: u8,
    signed: bool,
};

const Mapping = struct {
    name: []const u8,
    value: i64,
};

const TypeOrBitfieldType = union(enum) {
    type: Type,
    bitfield_type: BitfieldType,
};

const BitfieldField = struct {
    name: []const u8,
    type: BitfieldType,
};

const ArrayCount = union(enum) {
    type: NativeType,
    field: []const u8,
    constant: usize,
};

const BufferCount = union(enum) {
    type: NativeType,
    constant: usize,
};

const SwitchType = struct {
    compareTo: []const u8,
    fields: []Field,
    default: *Type,
};

const Type = union(enum) {
    reference: []const u8,
    todo,
    native: NativeType,
    container: struct { fields: []Field },
    bitfield: struct { fields: []BitfieldField },
    bitflags: struct { type: NativeType, flags: []const []const u8 },
    array: struct { count: ArrayCount, elementType: *Type },
    pstring: struct { countType: NativeType },
    option: *Type,
    buffer: BufferCount,
    topBitSetTerminatedArray: *Type,
    entityMetadataLoop: struct { endVal: i64, type: *Type },
    registryEntryHolder: struct { baseName: []const u8, otherwise: IndirectField },
    registryEntryHolderSet: struct { base: IndirectField, otherwise: IndirectField },
    switch_: SwitchType,
    mapper: struct { type: NativeType, mappings: []Mapping },

    pub fn fromJson(allocator: std.mem.Allocator, key: []const u8, json: std.json.Value) !Type {
        if (equalsString(json, "native")) {
            return .{ .native = try NativeType.fromString(key) };
        }
        if (isString(json)) |str| {
            return .{ .reference = str };
        }
        if (isConstructor(json)) |constructor| {
            if (std.mem.eql(u8, constructor.name, "container")) {
                const array = try expectArray(constructor.arg);
                var fields = try allocator.alloc(Field, array.items.len);
                for (0.., array.items) |i, field_json| {
                    const field_object = try expectObject(field_json);
                    const field_name = if (field_object.contains("name")) try expectString(try expectGet(field_object, "name")) else "anon";
                    const field_type = try Type.fromJson(allocator, field_name, try expectGet(field_object, "type"));
                    fields[i] = .{ .name = field_name, .type = field_type };
                }
                return .{ .container = .{ .fields = fields } };
            }
            if (std.mem.eql(u8, constructor.name, "mapper")) {
                const object = try expectObject(constructor.arg);
                const typ = try NativeType.fromString(try expectString(try expectGet(object, "type")));
                const mappings_object = try expectObject(try expectGet(object, "mappings"));
                var mappings = try allocator.alloc(Mapping, mappings_object.count());
                var i: usize = 0;
                var it = mappings_object.iterator();
                while (it.next()) |entry| : (i += 1) {
                    const value = try std.fmt.parseInt(i64, entry.key_ptr.*, 0);
                    mappings[i] = .{ .value = value, .name = try expectString(entry.value_ptr.*) };
                }
                return .{ .mapper = .{ .mappings = mappings, .type = typ } };
            }
            if (std.mem.eql(u8, constructor.name, "bitfield")) {
                const array = try expectArray(constructor.arg);
                var fields = try allocator.alloc(BitfieldField, array.items.len);
                for (0.., array.items) |i, field_json| {
                    const field_object = try expectObject(field_json);
                    const field_name = try expectString(try expectGet(field_object, "name"));
                    const field_size = try expectInteger(try expectGet(field_object, "size"));
                    const field_signed = try expectBoolean(try expectGet(field_object, "signed"));
                    fields[i] = .{ .name = field_name, .type = .{ .size = @intCast(field_size), .signed = field_signed } };
                }
                return .{ .bitfield = .{ .fields = fields } };
            }
            if (std.mem.eql(u8, constructor.name, "bitflags")) {
                const object = try expectObject(constructor.arg);
                const typ = try NativeType.fromString(try expectString(try expectGet(object, "type")));
                const flags_json = try expectArray(try expectGet(object, "flags"));
                var flags = try allocator.alloc([]const u8, flags_json.items.len);
                for (0.., flags_json.items) |i, flag_json| {
                    flags[i] = try expectString(flag_json);
                }
                return .{ .bitflags = .{ .type = typ, .flags = flags } };
            }
            if (std.mem.eql(u8, constructor.name, "array")) {
                const object = try expectObject(constructor.arg);
                const count: ArrayCount = if (object.get("countType")) |count_type|
                    .{ .type = try NativeType.fromString(try expectString(count_type)) }
                else switch (try expectGet(object, "count")) {
                    .string => |str| .{ .field = str },
                    .integer => |integer| .{ .constant = @intCast(integer) },
                    else => {
                        return error.UnexpectedTypeForCount;
                    },
                };

                const elementType = try allocator.create(Type);
                elementType.* = try Type.fromJson(allocator, "elementType", try expectGet(object, "type"));
                return .{ .array = .{ .count = count, .elementType = elementType } };
            }
            if (std.mem.eql(u8, constructor.name, "option")) {
                const child = try allocator.create(Type);
                child.* = try Type.fromJson(allocator, key, constructor.arg);
                return .{ .option = child };
            }
            if (std.mem.eql(u8, constructor.name, "buffer")) {
                const object = try expectObject(constructor.arg);
                const count: BufferCount = if (object.get("countType")) |count_type|
                    .{ .type = try NativeType.fromString(try expectString(count_type)) }
                else
                    .{ .constant = @intCast(try expectInteger(try expectGet(object, "count"))) };
                return .{ .buffer = count };
            }
            if (std.mem.eql(u8, constructor.name, "topBitSetTerminatedArray")) {
                const object = try expectObject(constructor.arg);
                const child = try allocator.create(Type);
                child.* = try Type.fromJson(allocator, key, try expectGet(object, "type"));
                return .{ .topBitSetTerminatedArray = child };
            }
            if (std.mem.eql(u8, constructor.name, "entityMetadataLoop")) {
                const object = try expectObject(constructor.arg);
                const child = try allocator.create(Type);
                child.* = try Type.fromJson(allocator, key, try expectGet(object, "type"));
                return .{ .entityMetadataLoop = .{
                    .endVal = try expectInteger(try expectGet(object, "endVal")),
                    .type = child,
                } };
            }
            if (std.mem.eql(u8, constructor.name, "registryEntryHolder")) {
                const object = try expectObject(constructor.arg);
                const otherwise_object = try expectObject(try expectGet(object, "otherwise"));
                const otherwise_name = try expectString(try expectGet(otherwise_object, "name"));
                const otherwise_type = try allocator.create(Type);
                otherwise_type.* = try Type.fromJson(allocator, otherwise_name, try expectGet(otherwise_object, "type"));
                return .{ .registryEntryHolder = .{
                    .baseName = try expectString(try expectGet(object, "baseName")),
                    .otherwise = .{
                        .name = otherwise_name,
                        .type = otherwise_type,
                    },
                } };
            }
            if (std.mem.eql(u8, constructor.name, "registryEntryHolderSet")) {
                const object = try expectObject(constructor.arg);
                const base_object = try expectObject(try expectGet(object, "base"));
                const otherwise_object = try expectObject(try expectGet(object, "otherwise"));
                const base_name = try expectString(try expectGet(base_object, "name"));
                const otherwise_name = try expectString(try expectGet(otherwise_object, "name"));
                const base_type = try allocator.create(Type);
                const otherwise_type = try allocator.create(Type);
                base_type.* = try Type.fromJson(allocator, base_name, try expectGet(base_object, "type"));
                otherwise_type.* = try Type.fromJson(allocator, otherwise_name, try expectGet(otherwise_object, "type"));
                return .{ .registryEntryHolderSet = .{
                    .base = .{
                        .name = base_name,
                        .type = base_type,
                    },
                    .otherwise = .{
                        .name = otherwise_name,
                        .type = otherwise_type,
                    },
                } };
            }
            if (std.mem.eql(u8, constructor.name, "pstring")) {
                const object = try expectObject(constructor.arg);
                const countType = try NativeType.fromString(try expectString(try expectGet(object, "countType")));

                return .{ .pstring = .{ .countType = countType } };
            }
            if (std.mem.eql(u8, constructor.name, "switch")) {
                const object = try expectObject(constructor.arg);
                const compareTo = try expectString(try expectGet(object, "compareTo"));
                const default = try allocator.create(Type);
                default.* = if (object.get("default")) |d|
                    try Type.fromJson(allocator, "default", d)
                else
                    .{ .native = .void };
                const fieldsObject = try expectObject(try expectGet(object, "fields"));
                var fields = try allocator.alloc(Field, fieldsObject.count());
                var it = fieldsObject.iterator();
                var i: usize = 0;
                while (it.next()) |entry| : (i += 1) {
                    const field_name = entry.key_ptr.*;
                    const field_type = try Type.fromJson(allocator, entry.key_ptr.*, entry.value_ptr.*);
                    fields[i] = .{ .name = field_name, .type = field_type };
                }
                return .{ .switch_ = .{ .compareTo = compareTo, .fields = fields, .default = default } };
            }
        }

        return .todo;
    }

    pub fn resolve(self: *const Type, allocator: std.mem.Allocator, scope: Scope, parentContainer: ?*ResolvedContainer) !*ResolvedType {
        switch (self.*) {
            .reference => |reference| {
                if (scope.outer.types.get(reference)) |referenced| {
                    return referenced.resolve(allocator, Scope{ .outer = scope.outer, .inner = null }, null);
                }
                if (scope.inner) |inner| {
                    if (inner.types.get(reference)) |referenced| {
                        return referenced.resolve(allocator, scope, parentContainer);
                    }
                }
                return error.UndefinedReference;
            },
            .container => |container| {
                const result = try allocator.create(ResolvedType);
                var fields = try allocator.alloc(ResolvedField, container.fields.len);
                result.* = .{ .container = .{ .fields = fields[0..0] } };
                for (0.., container.fields) |i, field| {
                    fields[i] = .{ .name = field.name, .type = try field.type.resolve(allocator, scope, &result.container) };
                    result.container.fields = fields[0 .. i + 1];
                }
                return result;
            },
            .native => |native| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .native = native };
                return result;
            },
            .pstring => |pstring| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .pstring = .{ .countType = pstring.countType } };
                return result;
            },
            .bitfield => |bitfield| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .bitfield = .{ .fields = bitfield.fields } };
                return result;
            },
            .bitflags => |bitflags| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .bitflags = .{ .type = bitflags.type, .flags = bitflags.flags } };
                return result;
            },
            .array => |array| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .array = .{
                    .count = array.count,
                    .elementType = try array.elementType.resolve(allocator, scope, parentContainer),
                } };
                return result;
            },
            .option => |option| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .option = try option.resolve(allocator, scope, parentContainer) };
                return result;
            },
            .buffer => |buffer| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .buffer = buffer };
                return result;
            },
            .topBitSetTerminatedArray => |array| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .topBitSetTerminatedArray = try array.resolve(allocator, scope, parentContainer) };
                return result;
            },
            .entityMetadataLoop => |loop| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .entityMetadataLoop = .{
                    .endVal = loop.endVal,
                    .type = try loop.type.resolve(allocator, scope, parentContainer),
                } };
                return result;
            },
            .registryEntryHolder => |holder| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .registryEntryHolder = .{
                    .baseName = holder.baseName,
                    .otherwise = .{
                        .name = holder.otherwise.name,
                        .type = try holder.otherwise.type.resolve(allocator, scope, parentContainer),
                    },
                } };
                return result;
            },
            .registryEntryHolderSet => |set| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .registryEntryHolderSet = .{
                    .base = .{
                        .name = set.base.name,
                        .type = try set.base.type.resolve(allocator, scope, parentContainer),
                    },
                    .otherwise = .{
                        .name = set.otherwise.name,
                        .type = try set.otherwise.type.resolve(allocator, scope, parentContainer),
                    },
                } };
                return result;
            },
            .switch_ => |switch_| {
                const compareTo = resolveReference(switch_.compareTo, parentContainer) catch {
                    const result = try allocator.create(ResolvedType);
                    result.* = .todo;
                    return result;
                };
                const result = try allocator.create(ResolvedType);
                var fields = try allocator.alloc(ResolvedVariant, switch_.fields.len);
                for (0.., switch_.fields) |i, field| {
                    fields[i] = .{
                        .value = field.name,
                        .type = try field.type.resolve(allocator, scope, parentContainer),
                    };
                }
                result.* = .{
                    .switch_ = .{
                        .compareTo = compareTo,
                        .variants = fields,
                        .default = try switch_.default.resolve(allocator, scope, parentContainer),
                    },
                };
                return result;
            },
            .mapper => |mapper| {
                const result = try allocator.create(ResolvedType);
                result.* = .{ .mapper = .{ .mappings = mapper.mappings, .type = mapper.type } };
                return result;
            },
            else => {
                const result = try allocator.create(ResolvedType);
                result.* = .todo;
                return result;
            },
        }
    }

    pub fn codegenAstViewAccessors(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, owner_name: []const u8, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
        const container = switch (self.*) {
            .reference => |reference| blk: {
                const referenced = scope.inner.?.types.get(reference) orelse scope.outer.types.get(reference) orelse return;
                break :blk switch (referenced) {
                    .container => |container| container,
                    else => return,
                };
            },
            .container => |container| container,
            else => return,
        };

        for (0.., container.fields) |i, field| {
            try field.type.codegenAstViewAccessor(types, writer, scope, owner_name, field.name, container.fields[0..i], carried_bindings, depth);
        }
    }

    fn codegenAstViewAccessor(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, owner_name: []const u8, field_name: []const u8, previous: []Field, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
        try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!{s} {{", .{ idfmt(field_name), try self.codegenAstReturnType(types, scope, owner_name, field_name, depth) });
        writer.indent();
        try writer.println("var rest = self.buffer;", .{});
        try writer.println("rest = rest[0..];", .{});
        var compare_names = try writer.allocator.alloc(?[]const u8, previous.len);
        defer {
            for (compare_names) |name| {
                if (name) |value| writer.allocator.free(value);
            }
            writer.allocator.free(compare_names);
        }
        @memset(compare_names, null);
        var bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, previous.len + carried_bindings.len);
        defer bindings.deinit(writer.allocator);
        try bindings.appendSlice(writer.allocator, carried_bindings);

        for (0.., previous) |i, field| {
            switch (field.type) {
                .switch_ => |switch_| {
                    const feeds_current_switch = switch (self.*) {
                        .switch_ => |current_switch| comparePathMatchesField(current_switch.compareTo, field.name),
                        else => false,
                    };
                    const feeds_current_array_count = switch (self.*) {
                        .array => |array| switch (array.count) {
                            .field => |count_field| std.mem.eql(u8, count_field, field.name),
                            else => false,
                        },
                        else => false,
                    };
                    const feeds_current_view = self.typeNeedsCompareBinding(types, scope, field.name, 16);
                    if ((fieldFeedsLaterSwitch(previous, i) or fieldFeedsLaterFieldCountArray(previous, i) or fieldFeedsLaterView(previous, i, types, scope) or feeds_current_switch or feeds_current_array_count or feeds_current_view) and field.type.canAstReadCompareValue(types, scope)) {
                        const compare_name = try std.fmt.allocPrint(writer.allocator, "field_compare_{}", .{writer.nextId()});
                        compare_names[i] = compare_name;
                        const compare_to = switch (self.*) {
                            .switch_ => |current_switch| if (comparePathMatchesField(current_switch.compareTo, field.name)) current_switch.compareTo else field.name,
                            else => field.name,
                        };
                        try field.type.codegenAstReadCompareValue(types, writer, scope, "rest", compare_name, compare_to, bindings.items, 12);
                        try bindings.append(writer.allocator, .{ .name = field.name, .type = &previous[i].type, .value_name = compare_name });
                    } else {
                        if (findPreviousCompareField(previous, i, switch_.compareTo)) |compare_index| {
                            if (compare_names[compare_index]) |compare_name| {
                                try field.type.codegenAstSwitchSkip(types, writer, scope, "rest", switch_, &previous[compare_index].type, compare_name, bindings.items, 12);
                            } else {
                                try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                            }
                        } else if (findCompareBinding(bindings.items, comparePathBase(switch_.compareTo))) |binding| {
                            try field.type.codegenAstSwitchSkip(types, writer, scope, "rest", switch_, binding.type, binding.value_name, bindings.items, 12);
                        } else {
                            try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                        }
                    }
                },
                .array => |array| {
                    if (array.count == .field) {
                        if (findPreviousField(previous, i, array.count.field)) |count_index| {
                            if (compare_names[count_index]) |count_name| {
                                try writer.println("for (0..@intCast({s})) |_| {{", .{count_name});
                                writer.indent();
                                try array.elementType.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                                writer.unindent();
                                try writer.println("}}", .{});
                            } else {
                                try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                            }
                        } else {
                            try field.type.codegenAstSkip(types, writer, scope, "rest");
                        }
                    } else {
                        try field.type.codegenAstSkip(types, writer, scope, "rest");
                    }
                },
                else => {
                    const feeds_current_switch = switch (self.*) {
                        .switch_ => |switch_| comparePathMatchesField(switch_.compareTo, field.name),
                        else => false,
                    };
                    const feeds_current_array_count = switch (self.*) {
                        .array => |array| switch (array.count) {
                            .field => |count_field| std.mem.eql(u8, count_field, field.name),
                            else => false,
                        },
                        else => false,
                    };
                    const feeds_current_view = self.typeNeedsCompareBinding(types, scope, field.name, 16);
                    if ((fieldFeedsLaterSwitch(previous, i) or fieldFeedsLaterFieldCountArray(previous, i) or fieldFeedsLaterView(previous, i, types, scope) or feeds_current_switch or feeds_current_array_count or feeds_current_view) and field.type.canAstReadCompareValue(types, scope)) {
                        const compare_name = try std.fmt.allocPrint(writer.allocator, "field_compare_{}", .{writer.nextId()});
                        compare_names[i] = compare_name;
                        const compare_to = switch (self.*) {
                            .switch_ => |switch_| if (comparePathMatchesField(switch_.compareTo, field.name)) switch_.compareTo else field.name,
                            else => field.name,
                        };
                        try field.type.codegenAstReadCompareValue(types, writer, scope, "rest", compare_name, compare_to, bindings.items, 12);
                        try bindings.append(writer.allocator, .{ .name = field.name, .type = &previous[i].type, .value_name = compare_name });
                    } else {
                        try field.type.codegenAstSkip(types, writer, scope, "rest");
                    }
                },
            }
        }
        switch (self.*) {
            .native => |native| try codegenAstNativeReturn(native, writer),
            .bitfield => |bitfield| try codegenBitfieldReadReturn(bitfield.fields, writer, "rest", false),
            .bitflags => |bitflags| try codegenBitflagsReadReturn(bitflags, writer, "rest", false),
            .reference => |reference| {
                if (resolveNativeAlias(types, scope, reference)) |native| {
                    try codegenAstNativeReturn(native, writer);
                } else if (resolveAlias(types, scope, reference)) |aliased| {
                    if (aliased.codegenAstIsScalar(types, scope)) {
                        try aliased.codegenAstReadAndReturnScalar(types, writer, scope, "rest");
                    } else {
                        const id = writer.nextId();
                        const child_bindings = try filterBindingsForType(writer.allocator, self, types, scope, bindings.items);
                        defer writer.allocator.free(child_bindings);
                        try writer.println("const field_start_{} = rest;", .{id});
                        try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                        try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), null, child_bindings);
                    }
                } else {
                    const id = writer.nextId();
                    const child_bindings = try filterBindingsForType(writer.allocator, self, types, scope, bindings.items);
                    defer writer.allocator.free(child_bindings);
                    try writer.println("const field_start_{} = rest;", .{id});
                    try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                    try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), null, child_bindings);
                }
            },
            .pstring => |pstring| {
                const id = writer.nextId();
                try writer.println("const field_value_{}, _ = try protocol_support.read_pstring(rest, {s});", .{ id, try pstring.countType.codegenType() });
                try writer.println("return field_value_{};", .{id});
            },
            .mapper => |mapper| {
                const id = writer.nextId();
                try writer.println("const field_value_{}, _ = try protocol_support.read_{s}(rest);", .{ id, @tagName(mapper.type) });
                try writer.println("return field_value_{};", .{id});
            },
            .switch_ => |switch_| {
                const id = writer.nextId();
                const child_bindings = try filterBindingsForType(writer.allocator, self, types, scope, bindings.items);
                defer writer.allocator.free(child_bindings);
                try writer.println("const field_start_{} = rest;", .{id});
                if (findPreviousCompareField(previous, previous.len, switch_.compareTo)) |compare_index| {
                    if (compare_names[compare_index]) |compare_name| {
                        try self.codegenAstSwitchSkip(types, writer, scope, "rest", switch_, &previous[compare_index].type, compare_name, bindings.items, 12);
                    } else {
                        try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                    }
                } else if (findCompareBinding(bindings.items, comparePathBase(switch_.compareTo))) |binding| {
                    try self.codegenAstSwitchSkip(types, writer, scope, "rest", switch_, binding.type, binding.value_name, bindings.items, 12);
                } else {
                    try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                }
                try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), null, child_bindings);
            },
            .array => |array| {
                const id = writer.nextId();
                const child_bindings = try filterBindingsForType(writer.allocator, self, types, scope, bindings.items);
                defer writer.allocator.free(child_bindings);
                try writer.println("const field_start_{} = rest;", .{id});
                switch (array.count) {
                    .field => |count_field| {
                        if (findPreviousField(previous, previous.len, count_field)) |count_index| {
                            if (compare_names[count_index]) |count_name| {
                                try writer.println("for (0..@intCast({s})) |_| {{", .{count_name});
                                writer.indent();
                                try array.elementType.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                                writer.unindent();
                                try writer.println("}}", .{});
                                try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), try std.fmt.allocPrint(writer.allocator, "@intCast({s})", .{count_name}), child_bindings);
                            } else {
                                try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                                try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), "0", child_bindings);
                            }
                        } else {
                            try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                            try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), "0", child_bindings);
                        }
                    },
                    else => {
                        try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                        try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), null, child_bindings);
                    },
                }
            },
            else => {
                const id = writer.nextId();
                const child_bindings = try filterBindingsForType(writer.allocator, self, types, scope, bindings.items);
                defer writer.allocator.free(child_bindings);
                try writer.println("const field_start_{} = rest;", .{id});
                try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", bindings.items, 12);
                try printViewInitializer(writer, try std.fmt.allocPrint(writer.allocator, "protocol_support.slice_to_rest(field_start_{}, rest)", .{id}), null, child_bindings);
            },
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenAstReturnType(self: *const Type, types: *const Types, scope: Scope, owner_name: []const u8, field_name: []const u8, depth: usize) ![]const u8 {
        return switch (self.*) {
            .native => |native| try native.codegenType(),
            .reference => |reference| if (resolveNativeAlias(types, scope, reference)) |native| try native.codegenType() else if (resolveAlias(types, scope, reference)) |aliased| switch (aliased.*) {
                .pstring => "[]const u8",
                .mapper => |mapper| try mapper.type.codegenType(),
                .bitfield => |bitfield| try codegenBitfieldValueType(types.allocator, bitfield.fields),
                .bitflags => |bitflags| try codegenBitflagsValueType(types.allocator, bitflags.flags),
                else => if (isNamedWriteTarget(reference)) try namedViewTypeName(types.allocator, reference) else if (depth >= max_ast_view_depth and !aliased.canAstViewPastDepth(types, scope, 4)) return error.UnsupportedTypedPayloadFallback else try astViewTypeName(types.allocator, owner_name, field_name, depth),
            } else "protocol_support.RawPayload",
            .pstring => "[]const u8",
            .mapper => |mapper| try mapper.type.codegenType(),
            .bitfield => |bitfield| try codegenBitfieldValueType(types.allocator, bitfield.fields),
            .bitflags => |bitflags| try codegenBitflagsValueType(types.allocator, bitflags.flags),
            else => if (depth >= max_ast_view_depth and !self.canAstViewPastDepth(types, scope, 4)) return error.UnsupportedTypedPayloadFallback else try astViewTypeName(types.allocator, owner_name, field_name, depth),
        };
    }

    pub fn codegenAstNestedViewTypes(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, owner_name: []const u8, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
        const container = switch (self.*) {
            .reference => |reference| blk: {
                const referenced = resolveAlias(types, scope, reference) orelse return;
                break :blk switch (referenced.*) {
                    .container => |container| container,
                    else => return,
                };
            },
            .container => |container| container,
            else => return,
        };

        var available = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, carried_bindings.len + container.fields.len);
        defer available.deinit(writer.allocator);
        try available.appendSlice(writer.allocator, carried_bindings);

        for (0.., container.fields) |i, field| {
            const is_compare_value = field.type.canAstReadCompareValue(types, scope);
            if (!field.type.codegenAstIsScalar(types, scope) and !field.type.isNamedWriteReference() and (depth < max_ast_view_depth or field.type.canAstViewPastDepth(types, scope, 4))) {
                const type_name = try astViewTypeName(types.allocator, owner_name, field.name, depth);
                defer types.allocator.free(type_name);
                const child_bindings = try filterBindingsForType(writer.allocator, &field.type, types, scope, available.items);
                defer writer.allocator.free(child_bindings);
                try field.type.codegenAstViewTypeWithCompares(types, writer, scope, type_name, child_bindings, depth + 1);
            }
            if (is_compare_value) {
                try available.append(writer.allocator, .{ .name = field.name, .type = &container.fields[i].type, .value_name = field.name });
            }
        }
    }

    fn codegenAstViewType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, depth: usize) anyerror!void {
        try self.codegenAstViewTypeWithCompares(types, writer, scope, type_name, &.{}, depth);
    }

    fn codegenAstViewTypeWithCompares(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
        if (depth > max_ast_view_depth and !self.canAstViewPastDepth(types, scope, 4)) return;

        const actual = switch (self.*) {
            .reference => |reference| resolveAlias(types, scope, reference) orelse self,
            else => self,
        };
        var view_bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, carried_bindings.len);
        defer {
            for (view_bindings.items) |binding| writer.allocator.free(binding.value_name);
            view_bindings.deinit(writer.allocator);
        }
        for (carried_bindings) |binding| {
            const field_name = try compareBindingFieldName(writer.allocator, binding.name);
            defer writer.allocator.free(field_name);
            const value_name = try std.fmt.allocPrint(writer.allocator, "self.{s}", .{field_name});
            try view_bindings.append(writer.allocator, .{ .name = binding.name, .type = binding.type, .value_name = value_name });
        }

        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try writer.println("buffer: []const u8,", .{});
        if (actual.* == .array and actual.array.count == .field) try writer.println("remaining: usize,", .{});
        for (carried_bindings) |binding| {
            const field_name = try compareBindingFieldName(writer.allocator, binding.name);
            defer writer.allocator.free(field_name);
            try writer.println("{s}: {s},", .{ field_name, try compareBindingStorageType(binding, types, scope) });
        }
        try writer.println("", .{});

        switch (actual.*) {
            .container => {
                const container = switch (actual.*) {
                    .container => |container| container,
                    else => unreachable,
                };
                try codegenAstContainerReadCursorEntry(types, writer, scope, type_name, container.fields, carried_bindings);
            },
            .array => |array| {
                try actual.codegenAstArrayView(types, writer, scope, type_name, array, view_bindings.items, depth);
            },
            .option => |option| {
                try option.codegenAstOptionView(types, writer, scope, type_name, depth);
            },
            .registryEntryHolder => |holder| {
                try holder.otherwise.type.codegenAstRegistryEntryHolderView(types, writer, scope, type_name, holder, depth);
            },
            .switch_ => |switch_| {
                try actual.codegenAstSwitchView(types, writer, scope, type_name, switch_, view_bindings.items, depth);
            },
            else => {},
        }

        if (!actual.hasAstViewAccessor(types, scope, "payload")) {
            try writer.println("pub fn payload(self: @This()) []const u8 {{", .{});
            writer.indent();
            try writer.println("return self.buffer;", .{});
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
        }
        try writer.println("pub fn finish(self: @This()) protocol_support.ReadError!void {{", .{});
        writer.indent();
        try writer.println("var rest = self.buffer;", .{});
        try writer.println("rest = rest[0..];", .{});
        if (actual.* == .array and actual.array.count == .field) {
            try writer.println("for (0..self.remaining) |_| {{", .{});
            writer.indent();
            try actual.array.elementType.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", view_bindings.items, 12);
            writer.unindent();
            try writer.println("}}", .{});
        } else if (actual.* == .switch_) {
            try writer.println("try (protocol_support.FinalCursor{{ .buffer = rest }}).finish();", .{});
            writer.unindent();
            try writer.println("}}", .{});
            writer.unindent();
            try writer.println("}};", .{});
            try writer.println("", .{});

            switch (actual.*) {
                .switch_ => |switch_| {
                    for (switch_.fields) |field| {
                        if (field.type.codegenAstIsScalar(types, scope)) continue;
                        if (field.type.isNamedWriteReference()) continue;
                        if (depth >= max_ast_view_depth and !field.type.canAstViewPastDepth(types, scope, 4)) continue;
                        const method_name = try switchCaseMethodName(types.allocator, field.name);
                        defer types.allocator.free(method_name);
                        const child_name = try std.fmt.allocPrint(types.allocator, "{s}__{s}", .{ type_name, method_name });
                        defer types.allocator.free(child_name);
                        const child_bindings = try filterBindingsForType(writer.allocator, &field.type, types, scope, view_bindings.items);
                        defer writer.allocator.free(child_bindings);
                        try field.type.codegenAstViewTypeWithCompares(types, writer, scope, child_name, child_bindings, depth + 1);
                    }
                    if (!switch_.default.isNamedWriteReference() and !switch_.default.codegenAstIsScalar(types, scope) and (depth < max_ast_view_depth or switch_.default.canAstViewPastDepth(types, scope, 4))) {
                        const child_name = try std.fmt.allocPrint(types.allocator, "{s}__case_default", .{type_name});
                        defer types.allocator.free(child_name);
                        const child_bindings = try filterBindingsForType(writer.allocator, switch_.default, types, scope, view_bindings.items);
                        defer writer.allocator.free(child_bindings);
                        try switch_.default.codegenAstViewTypeWithCompares(types, writer, scope, child_name, child_bindings, depth + 1);
                    }
                },
                else => unreachable,
            }
            return;
        } else {
            try actual.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", view_bindings.items, 12);
        }
        try writer.println("try (protocol_support.FinalCursor{{ .buffer = rest }}).finish();", .{});
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        switch (actual.*) {
            .container => |container| try codegenAstContainerReadCursorTailTypes(types, writer, scope, type_name, container.fields, carried_bindings, depth),
            .array => |array| {
                if (!array.elementType.isNamedWriteReference() and !array.elementType.codegenAstIsScalar(types, scope) and (depth < max_ast_view_depth or array.elementType.canAstViewPastDepth(types, scope, 4))) {
                    const element_name = try std.fmt.allocPrint(types.allocator, "{s}__element", .{type_name});
                    defer types.allocator.free(element_name);
                    const child_bindings = try filterBindingsForType(writer.allocator, array.elementType, types, scope, view_bindings.items);
                    defer writer.allocator.free(child_bindings);
                    try array.elementType.codegenAstViewTypeWithCompares(types, writer, scope, element_name, child_bindings, depth + 1);
                }
            },
            .option => |option| {
                if (!option.isNamedWriteReference() and !option.codegenAstIsScalar(types, scope) and (depth < max_ast_view_depth or option.canAstViewPastDepth(types, scope, 4))) {
                    const child_name = try std.fmt.allocPrint(types.allocator, "{s}__value", .{type_name});
                    defer types.allocator.free(child_name);
                    const child_bindings = try filterBindingsForType(writer.allocator, option, types, scope, view_bindings.items);
                    defer writer.allocator.free(child_bindings);
                    try option.codegenAstViewTypeWithCompares(types, writer, scope, child_name, child_bindings, depth + 1);
                }
            },
            .registryEntryHolder => |holder| {
                if (!holder.otherwise.type.codegenAstIsScalar(types, scope) and (depth < max_ast_view_depth or holder.otherwise.type.canAstViewPastDepth(types, scope, 4))) {
                    const child_name = try std.fmt.allocPrint(types.allocator, "{s}__{s}", .{ type_name, holder.otherwise.name });
                    defer types.allocator.free(child_name);
                    const child_bindings = try filterBindingsForType(writer.allocator, holder.otherwise.type, types, scope, view_bindings.items);
                    defer writer.allocator.free(child_bindings);
                    try holder.otherwise.type.codegenAstViewTypeWithCompares(types, writer, scope, child_name, child_bindings, depth + 1);
                }
            },
            .switch_ => |switch_| {
                for (switch_.fields) |field| {
                    if (field.type.codegenAstIsScalar(types, scope)) continue;
                    if (field.type.isNamedWriteReference()) continue;
                    if (depth >= max_ast_view_depth and !field.type.canAstViewPastDepth(types, scope, 4)) continue;
                    const method_name = try switchCaseMethodName(types.allocator, field.name);
                    defer types.allocator.free(method_name);
                    const child_name = try std.fmt.allocPrint(types.allocator, "{s}__{s}", .{ type_name, method_name });
                    defer types.allocator.free(child_name);
                    const child_bindings = try filterBindingsForType(writer.allocator, &field.type, types, scope, view_bindings.items);
                    defer writer.allocator.free(child_bindings);
                    try field.type.codegenAstViewTypeWithCompares(types, writer, scope, child_name, child_bindings, depth + 1);
                }
                if (!switch_.default.isNamedWriteReference() and !switch_.default.codegenAstIsScalar(types, scope) and (depth < max_ast_view_depth or switch_.default.canAstViewPastDepth(types, scope, 4))) {
                    const child_name = try std.fmt.allocPrint(types.allocator, "{s}__case_default", .{type_name});
                    defer types.allocator.free(child_name);
                    const child_bindings = try filterBindingsForType(writer.allocator, switch_.default, types, scope, view_bindings.items);
                    defer writer.allocator.free(child_bindings);
                    try switch_.default.codegenAstViewTypeWithCompares(types, writer, scope, child_name, child_bindings, depth + 1);
                }
            },
            else => {},
        }
    }

    fn codegenAstSwitchView(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, switch_: SwitchType, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
        _ = self;
        for (switch_.fields) |field| {
            const method_name = try switchCaseMethodName(types.allocator, field.name);
            defer types.allocator.free(method_name);
            try field.type.codegenAstSwitchCaseViewMethod(types, writer, scope, type_name, method_name, carried_bindings, depth);
            try writer.println("", .{});
        }
        try switch_.default.codegenAstSwitchCaseViewMethod(types, writer, scope, type_name, "case_default", carried_bindings, depth);
        try writer.println("", .{});
    }

    fn codegenAstSwitchCaseViewMethod(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, method_name: []const u8, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
        const return_type = try self.codegenAstSwitchCaseReturnType(types, scope, type_name, method_name, depth);
        defer if (std.mem.startsWith(u8, return_type, "view")) types.allocator.free(return_type);

        try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!{s} {{", .{ idfmt(method_name), return_type });
        writer.indent();
        try writer.println("var rest = self.buffer;", .{});
        try writer.println("rest = rest[0..];", .{});
        if (self.codegenAstIsScalar(types, scope)) {
            try self.codegenAstReadAndReturnScalar(types, writer, scope, "rest");
        } else {
            const child_bindings = try filterBindingsForType(writer.allocator, self, types, scope, carried_bindings);
            defer writer.allocator.free(child_bindings);
            try writer.println("const field_start = rest;", .{});
            try self.codegenAstSkipDepthWithCompares(types, writer, scope, "rest", carried_bindings, 12);
            try printViewInitializer(writer, "protocol_support.slice_to_rest(field_start, rest)", null, child_bindings);
        }
        writer.unindent();
        try writer.println("}}", .{});
    }

    fn codegenAstSwitchCaseReturnType(self: *const Type, types: *const Types, scope: Scope, type_name: []const u8, method_name: []const u8, depth: usize) ![]const u8 {
        switch (self.*) {
            .reference => |reference| if (isNamedWriteTarget(reference)) return namedViewTypeName(types.allocator, reference),
            else => {},
        }
        const actual = self.resolveAstWriteAlias(types, scope);
        return switch (actual.*) {
            .native => |native| try native.codegenType(),
            .pstring => "[]const u8",
            .mapper => |mapper| try mapper.type.codegenType(),
            .bitfield => |bitfield| try codegenBitfieldValueType(types.allocator, bitfield.fields),
            .bitflags => |bitflags| try codegenBitflagsValueType(types.allocator, bitflags.flags),
            else => if (depth >= max_ast_view_depth and !actual.canAstViewPastDepth(types, scope, 4))
                return error.UnsupportedTypedPayloadFallback
            else
                try std.fmt.allocPrint(types.allocator, "{s}__{s}", .{ type_name, method_name }),
        };
    }

    fn codegenAstArrayView(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, array: anytype, carried_bindings: []const CompareBinding, depth: usize) anyerror!void {
        _ = self;
        const element_type = try array.elementType.codegenAstElementReturnType(types, scope, type_name, depth);
        defer if (std.mem.startsWith(u8, element_type, "view")) types.allocator.free(element_type);
        const element_bindings = try filterBindingsForType(writer.allocator, array.elementType, types, scope, carried_bindings);
        defer writer.allocator.free(element_bindings);

        try writer.println("pub const Iterator = struct {{", .{});
        writer.indent();
        try writer.println("rest: []const u8,", .{});
        try writer.println("remaining: usize,", .{});
        for (carried_bindings) |binding| {
            const field_name = try compareBindingFieldName(writer.allocator, binding.name);
            defer writer.allocator.free(field_name);
            try writer.println("{s}: {s},", .{ field_name, try compareBindingStorageType(binding, types, scope) });
        }
        try writer.println("", .{});
        try writer.println("pub fn next(self: *@This()) protocol_support.ReadError!?{s} {{", .{element_type});
        writer.indent();
        try writer.println("if (self.remaining == 0) return null;", .{});
        try writer.println("self.remaining -= 1;", .{});
        if (array.elementType.codegenAstIsScalar(types, scope)) {
            try array.elementType.codegenAstReadAndReturnScalar(types, writer, scope, "self.rest");
        } else {
            try writer.println("const field_start = self.rest;", .{});
            try array.elementType.codegenAstSkipDepthWithCompares(types, writer, scope, "self.rest", carried_bindings, 12);
            try printViewInitializer(writer, "protocol_support.slice_to_rest(field_start, self.rest)", null, element_bindings);
        }
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});
        try writer.println("pub fn iter(self: @This()) protocol_support.ReadError!Iterator {{", .{});
        writer.indent();
        switch (array.count) {
            .field => {
                try writer.println("const rest = self.buffer;", .{});
                try printIteratorInitializer(writer, "rest", "self.remaining", carried_bindings);
            },
            else => {
                try writer.println("var rest = self.buffer;", .{});
                const count_id = try codegenArrayCountRead(array.count, writer, "rest");
                try printIteratorInitializer(writer, "rest", try std.fmt.allocPrint(writer.allocator, "@intCast(count_{})", .{count_id}), carried_bindings);
            },
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
        try writer.println("pub fn len(self: @This()) protocol_support.ReadError!usize {{", .{});
        writer.indent();
        switch (array.count) {
            .constant => |constant| {
                try writer.println("_ = self;", .{});
                try writer.println("return {};", .{constant});
            },
            .type => |countType| {
                try writer.println("const count, _ = try protocol_support.read_{s}(self.buffer);", .{@tagName(countType)});
                try writer.println("return @intCast(count);", .{});
            },
            .field => {
                try writer.println("return self.remaining;", .{});
            },
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenAstOptionView(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, depth: usize) anyerror!void {
        const value_type = if (self.codegenAstIsScalar(types, scope))
            try self.codegenAstElementReturnType(types, scope, type_name, depth)
        else if (self.isNamedWriteReference())
            try namedViewTypeName(types.allocator, self.reference)
        else if (depth >= max_ast_view_depth and !self.canAstViewPastDepth(types, scope, 4))
            return error.UnsupportedTypedPayloadFallback
        else
            try std.fmt.allocPrint(types.allocator, "{s}__value", .{type_name});
        defer if (std.mem.startsWith(u8, value_type, "view")) types.allocator.free(value_type);

        try writer.println("pub fn value(self: @This()) protocol_support.ReadError!?{s} {{", .{value_type});
        writer.indent();
        try writer.println("const present, var rest = try protocol_support.read_bool(self.buffer);", .{});
        try writer.println("if (!present) return null;", .{});
        if (self.codegenAstIsScalar(types, scope)) {
            try self.codegenAstReadAndReturnScalar(types, writer, scope, "rest");
        } else {
            try writer.println("const field_start = rest;", .{});
            try self.codegenAstSkip(types, writer, scope, "rest");
            try writer.println("return .{{ .buffer = protocol_support.slice_to_rest(field_start, rest) }};", .{});
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenAstRegistryEntryHolderView(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, holder: anytype, depth: usize) anyerror!void {
        const data_type = if (self.codegenAstIsScalar(types, scope))
            try self.codegenAstElementReturnType(types, scope, type_name, depth)
        else if (self.isNamedWriteReference())
            try namedViewTypeName(types.allocator, self.reference)
        else if (depth >= max_ast_view_depth and !self.canAstViewPastDepth(types, scope, 4))
            return error.UnsupportedTypedPayloadFallback
        else
            try std.fmt.allocPrint(types.allocator, "{s}__{s}", .{ type_name, holder.otherwise.name });
        defer if (std.mem.startsWith(u8, data_type, "view")) types.allocator.free(data_type);

        try writer.println("pub fn value(self: @This()) protocol_support.ReadError!union(enum) {{", .{});
        writer.indent();
        try writer.println("{f}: i32,", .{idfmt(holder.baseName)});
        try writer.println("{f}: {s},", .{ idfmt(holder.otherwise.name), data_type });
        writer.unindent();
        try writer.println("}} {{", .{});
        writer.indent();
        if (self.codegenAstIsScalar(types, scope)) {
            try writer.println("const holder_id, const rest = try protocol_support.read_varint(self.buffer);", .{});
        } else {
            try writer.println("const holder_id, var rest = try protocol_support.read_varint(self.buffer);", .{});
        }
        try writer.println("if (holder_id != 0) return .{{ .{f} = holder_id }};", .{idfmt(holder.baseName)});
        if (self.codegenAstIsScalar(types, scope)) {
            const actual = self.resolveAstWriteAlias(types, scope);
            switch (actual.*) {
                .native => |native| {
                    if (native == .void) {
                        try writer.println("return .{{ .{f} = {{}} }};", .{idfmt(holder.otherwise.name)});
                    } else {
                        try writer.println("const scalar_value, _ = try protocol_support.read_{s}(rest);", .{@tagName(native)});
                        try writer.println("return .{{ .{f} = scalar_value }};", .{idfmt(holder.otherwise.name)});
                    }
                },
                .pstring => |pstring| {
                    try writer.println("const scalar_value, _ = try protocol_support.read_pstring(rest, {s});", .{try pstring.countType.codegenType()});
                    try writer.println("return .{{ .{f} = scalar_value }};", .{idfmt(holder.otherwise.name)});
                },
                .bitfield => |bitfield| {
                    const id = writer.nextId();
                    try writer.println("const packed_{}, _ = try protocol_support.read_packed_bits(rest, {});", .{ id, bitfieldBits(bitfield.fields) });
                    try printIndent(writer.writer, writer.level);
                    try writer.writer.print("return .{{ .{f} = ", .{idfmt(holder.otherwise.name)});
                    try codegenBitfieldValueLiteral(bitfield.fields, writer, try std.fmt.allocPrint(writer.allocator, "packed_{}", .{id}));
                    try writer.writer.print(" }};\n", .{});
                },
                .bitflags => |bitflags| {
                    const id = writer.nextId();
                    try writer.println("const flags_{}, _ = try protocol_support.read_{s}(rest);", .{ id, @tagName(bitflags.type) });
                    try printIndent(writer.writer, writer.level);
                    try writer.writer.print("return .{{ .{f} = ", .{idfmt(holder.otherwise.name)});
                    try codegenBitflagsValueLiteral(bitflags, writer, try std.fmt.allocPrint(writer.allocator, "flags_{}", .{id}));
                    try writer.writer.print(" }};\n", .{});
                },
                else => try writer.println("return error.EndOfStream;", .{}),
            }
        } else {
            try writer.println("const start = rest;", .{});
            try self.codegenAstSkip(types, writer, scope, "rest");
            try writer.println("return .{{ .{f} = .{{ .buffer = protocol_support.slice_to_rest(start, rest) }} }};", .{idfmt(holder.otherwise.name)});
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenAstRemainingExpr(self: *const Type, types: *const Types, scope: Scope, allocator: std.mem.Allocator, bindings: []const CompareBinding) !?[]const u8 {
        const actual = self.resolveAstWriteAlias(types, scope);
        return switch (actual.*) {
            .array => |array| switch (array.count) {
                .field => |field| if (findCompareBinding(bindings, field)) |binding|
                    try std.fmt.allocPrint(allocator, "@intCast({s})", .{binding.value_name})
                else
                    null,
                else => null,
            },
            else => null,
        };
    }

    fn codegenAstElementReturnType(self: *const Type, types: *const Types, scope: Scope, type_name: []const u8, depth: usize) ![]const u8 {
        return switch (self.*) {
            .native => |native| try native.codegenType(),
            .reference => |reference| if (resolveNativeAlias(types, scope, reference)) |native| try native.codegenType() else if (resolveAlias(types, scope, reference)) |aliased| switch (aliased.*) {
                .pstring => "[]const u8",
                .mapper => |mapper| try mapper.type.codegenType(),
                .bitfield => |bitfield| try codegenBitfieldValueType(types.allocator, bitfield.fields),
                .bitflags => |bitflags| try codegenBitflagsValueType(types.allocator, bitflags.flags),
                else => if (isNamedWriteTarget(reference)) try namedViewTypeName(types.allocator, reference) else if (depth >= max_ast_view_depth and !aliased.canAstViewPastDepth(types, scope, 4)) return error.UnsupportedTypedPayloadFallback else try std.fmt.allocPrint(types.allocator, "{s}__element", .{type_name}),
            } else "protocol_support.RawPayload",
            .pstring => "[]const u8",
            .mapper => |mapper| try mapper.type.codegenType(),
            .bitfield => |bitfield| try codegenBitfieldValueType(types.allocator, bitfield.fields),
            .bitflags => |bitflags| try codegenBitflagsValueType(types.allocator, bitflags.flags),
            else => if (depth >= max_ast_view_depth and !self.canAstViewPastDepth(types, scope, 4)) return error.UnsupportedTypedPayloadFallback else try std.fmt.allocPrint(types.allocator, "{s}__element", .{type_name}),
        };
    }

    fn codegenAstIsScalar(self: *const Type, types: *const Types, scope: Scope) bool {
        return switch (self.*) {
            .native, .pstring, .mapper, .bitfield, .bitflags => true,
            .reference => |reference| if (resolveNativeAlias(types, scope, reference)) |_| true else if (resolveAlias(types, scope, reference)) |aliased| switch (aliased.*) {
                .pstring, .mapper, .bitfield, .bitflags => true,
                else => false,
            } else false,
            else => false,
        };
    }

    fn codegenAstReadAndReturnScalar(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8) anyerror!void {
        switch (self.*) {
            .native => |native| {
                if (native == .void) {
                    try writer.println("return {{}};", .{});
                } else {
                    try writer.println("const scalar_value, const after_scalar = try protocol_support.read_{s}({s});", .{ @tagName(native), restName });
                    try writer.println("{s} = after_scalar;", .{restName});
                    try writer.println("return scalar_value;", .{});
                }
            },
            .reference => |reference| {
                if (resolveNativeAlias(types, scope, reference)) |native| {
                    const native_type = Type{ .native = native };
                    try native_type.codegenAstReadAndReturnScalar(types, writer, scope, restName);
                } else if (resolveAlias(types, scope, reference)) |aliased| {
                    try aliased.codegenAstReadAndReturnScalar(types, writer, scope, restName);
                } else {
                    try writer.println("return error.EndOfStream;", .{});
                }
            },
            .pstring => |pstring| {
                try writer.println("const scalar_value, const after_scalar = try protocol_support.read_pstring({s}, {s});", .{ restName, try pstring.countType.codegenType() });
                try writer.println("{s} = after_scalar;", .{restName});
                try writer.println("return scalar_value;", .{});
            },
            .buffer => |buffer| {
                switch (buffer) {
                    .constant => |count| try writer.println("const scalar_value, const after_scalar = try protocol_support.read_buffer_exact({s}, {});", .{ restName, count }),
                    .type => |countType| try writer.println("const scalar_value, const after_scalar = try protocol_support.read_buffer_counted({s}, {s});", .{ restName, try countType.codegenType() }),
                }
                try writer.println("{s} = after_scalar;", .{restName});
                try writer.println("return scalar_value;", .{});
            },
            .mapper => |mapper| {
                try writer.println("const scalar_value, const after_scalar = try protocol_support.read_{s}({s});", .{ @tagName(mapper.type), restName });
                try writer.println("{s} = after_scalar;", .{restName});
                try writer.println("return scalar_value;", .{});
            },
            .bitfield => |bitfield| try codegenBitfieldReadReturn(bitfield.fields, writer, restName, true),
            .bitflags => |bitflags| try codegenBitflagsReadReturn(bitflags, writer, restName, true),
            else => try writer.println("return error.EndOfStream;", .{}),
        }
    }

    pub fn codegenAstSkip(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8) anyerror!void {
        try self.codegenAstSkipDepth(types, writer, scope, restName, 12);
    }

    fn codegenAstSkipDepth(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8, budget: usize) anyerror!void {
        try self.codegenAstSkipDepthWithCompares(types, writer, scope, restName, &.{}, budget);
    }

    fn codegenAstSkipDepthWithCompares(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8, parent_bindings: []const CompareBinding, budget: usize) anyerror!void {
        if (budget == 0) {
            try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName });
            return;
        }

        switch (self.*) {
            .native => |native| try codegenNativeSkip(native, writer, restName),
            .reference => |reference| {
                if (isNamedWriteTarget(reference)) {
                    const skip_name = try namedSkipFunctionName(types.allocator, reference);
                    defer types.allocator.free(skip_name);
                    try writer.println("{s} = try {s}({s});", .{ restName, skip_name, restName });
                    return;
                }
                if (resolveNativeAlias(types, scope, reference)) |native| {
                    try codegenNativeSkip(native, writer, restName);
                    return;
                }
                if (resolveAlias(types, scope, reference)) |aliased| switch (aliased.*) {
                    .pstring, .buffer, .option, .array, .container, .bitfield, .bitflags, .mapper, .topBitSetTerminatedArray, .entityMetadataLoop, .registryEntryHolder, .registryEntryHolderSet => {
                        try aliased.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                        return;
                    },
                    else => {},
                };
                try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName });
            },
            .pstring => |pstring| try writer.println("{s} = (try protocol_support.read_pstring({s}, {s}))[1];", .{ restName, restName, try pstring.countType.codegenType() }),
            .buffer => |buffer| switch (buffer) {
                .constant => |count| try writer.println("{s} = (try protocol_support.read_buffer_exact({s}, {}))[1];", .{ restName, restName, count }),
                .type => |countType| try writer.println("{s} = (try protocol_support.read_buffer_counted({s}, {s}))[1];", .{ restName, restName, try countType.codegenType() }),
            },
            .container => |container| {
                var compare_names = try writer.allocator.alloc(?[]const u8, container.fields.len);
                defer {
                    for (compare_names) |name| {
                        if (name) |value| writer.allocator.free(value);
                    }
                    writer.allocator.free(compare_names);
                }
                @memset(compare_names, null);
                var bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, parent_bindings.len);
                defer bindings.deinit(writer.allocator);
                try bindings.appendSlice(writer.allocator, parent_bindings);

                for (0.., container.fields) |i, field| {
                    switch (field.type) {
                        .switch_ => |switch_| {
                            if ((fieldFeedsLaterSwitch(container.fields, i) or fieldFeedsLaterFieldCountArray(container.fields, i) or fieldFeedsLaterView(container.fields, i, types, scope)) and field.type.canAstReadCompareValue(types, scope)) {
                                const compare_name = try std.fmt.allocPrint(writer.allocator, "skip_compare_{}", .{writer.nextId()});
                                compare_names[i] = compare_name;
                                const compare_to = laterSwitchCompareForField(container.fields, i) orelse field.name;
                                try field.type.codegenAstReadCompareValue(types, writer, scope, restName, compare_name, compare_to, bindings.items, budget - 1);
                                try bindings.append(writer.allocator, .{ .name = field.name, .type = &container.fields[i].type, .value_name = compare_name });
                            } else {
                                if (findPreviousCompareField(container.fields, i, switch_.compareTo)) |compare_index| {
                                    if (compare_names[compare_index]) |compare_name| {
                                        try field.type.codegenAstSwitchSkip(types, writer, scope, restName, switch_, &container.fields[compare_index].type, compare_name, bindings.items, budget - 1);
                                    } else {
                                        try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                                    }
                                } else if (findCompareBinding(bindings.items, comparePathBase(switch_.compareTo))) |binding| {
                                    try field.type.codegenAstSwitchSkip(types, writer, scope, restName, switch_, binding.type, binding.value_name, bindings.items, budget - 1);
                                } else {
                                    try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                                }
                            }
                        },
                        .array => |array| {
                            if (array.count == .field) {
                                if (findPreviousField(container.fields, i, array.count.field)) |count_index| {
                                    if (compare_names[count_index]) |count_name| {
                                        try writer.println("for (0..@intCast({s})) |_| {{", .{count_name});
                                        writer.indent();
                                        try array.elementType.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                                        writer.unindent();
                                        try writer.println("}}", .{});
                                    } else {
                                        try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                                    }
                                } else {
                                    try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                                }
                            } else {
                                try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                            }
                        },
                        else => {
                            if ((fieldFeedsLaterSwitch(container.fields, i) or fieldFeedsLaterFieldCountArray(container.fields, i) or fieldFeedsLaterView(container.fields, i, types, scope)) and field.type.canAstReadCompareValue(types, scope)) {
                                const compare_name = try std.fmt.allocPrint(writer.allocator, "skip_compare_{}", .{writer.nextId()});
                                compare_names[i] = compare_name;
                                const compare_to = laterSwitchCompareForField(container.fields, i) orelse field.name;
                                try field.type.codegenAstReadCompareValue(types, writer, scope, restName, compare_name, compare_to, bindings.items, budget - 1);
                                try bindings.append(writer.allocator, .{ .name = field.name, .type = &container.fields[i].type, .value_name = compare_name });
                            } else {
                                try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                            }
                        },
                    }
                }
            },
            .bitfield => |bitfield| try writer.println("{s} = (try protocol_support.read_packed_bits({s}, {}))[1];", .{ restName, restName, bitfieldBits(bitfield.fields) }),
            .bitflags => |bitflags| try codegenNativeSkip(bitflags.type, writer, restName),
            .registryEntryHolder => |holder| {
                const id = writer.nextId();
                try writer.println("const holder_{}, const rest_{} = try protocol_support.read_varint({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (holder_{} == 0) {{", .{id});
                writer.indent();
                try holder.otherwise.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .registryEntryHolderSet => |set| {
                const id = writer.nextId();
                try writer.println("const holder_set_count_{}, const rest_{} = try protocol_support.read_varint({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (holder_set_count_{} == 0) {{", .{id});
                writer.indent();
                try set.base.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                writer.unindent();
                try writer.println("}} else {{", .{});
                writer.indent();
                try writer.println("for (0..@intCast(holder_set_count_{} - 1)) |_| {{", .{id});
                writer.indent();
                try set.otherwise.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}}", .{});
            },
            .topBitSetTerminatedArray => |array| {
                try writer.println("while (true) {{", .{});
                writer.indent();
                const id = writer.nextId();
                try writer.println("const marker_{}, const rest_{} = try protocol_support.read_i8({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                const actual = array.resolveAstWriteAlias(types, scope);
                if (actual.* == .container) {
                    try codegenAstSkipFields(types, writer, scope, restName, actual.container.fields[1..], parent_bindings, budget - 1);
                } else {
                    try array.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                }
                try writer.println("if (marker_{} >= 0) break;", .{id});
                writer.unindent();
                try writer.println("}}", .{});
            },
            .entityMetadataLoop => |loop| {
                try writer.println("while (true) {{", .{});
                writer.indent();
                const id = writer.nextId();
                try writer.println("const marker_{}, const rest_{} = try protocol_support.read_u8({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (marker_{} == {}) break;", .{ id, loop.endVal });
                const actual = loop.type.resolveAstWriteAlias(types, scope);
                if (actual.* == .container) {
                    try codegenAstSkipFields(types, writer, scope, restName, actual.container.fields[1..], parent_bindings, budget - 1);
                } else {
                    try loop.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                }
                writer.unindent();
                try writer.println("}}", .{});
            },
            .array => |array| {
                const count_expr = switch (array.count) {
                    .field => |field| if (findCompareBinding(parent_bindings, field)) |binding|
                        try writer.allocator.dupe(u8, binding.value_name)
                    else
                        null,
                    else => null,
                };
                defer if (count_expr) |expr| writer.allocator.free(expr);
                if (count_expr) |expr| {
                    try writer.println("for (0..@intCast({s})) |_| {{", .{expr});
                } else {
                    const count_id = try codegenArrayCountRead(array.count, writer, restName);
                    try writer.println("for (0..@intCast(count_{})) |_| {{", .{count_id});
                }
                writer.indent();
                try array.elementType.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .option => |option| {
                const id = writer.nextId();
                try writer.println("const present_{}, const rest_{} = try protocol_support.read_bool({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (present_{}) {{", .{id});
                writer.indent();
                try option.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .switch_ => |switch_| {
                if (findCompareBinding(parent_bindings, comparePathBase(switch_.compareTo))) |binding| {
                    try self.codegenAstSwitchSkip(types, writer, scope, restName, switch_, binding.type, binding.value_name, parent_bindings, budget - 1);
                } else {
                    try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName });
                }
            },
            .mapper => |mapper| try writer.println("{s} = (try protocol_support.read_{s}({s}))[1];", .{ restName, @tagName(mapper.type), restName }),
            else => try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName }),
        }
    }

    fn codegenAstReadCompareValue(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8, compareName: []const u8, compareTo: []const u8, parent_bindings: []const CompareBinding, budget: usize) anyerror!void {
        const actual = self.resolveAstWriteAlias(types, scope);
        switch (actual.*) {
            .native => |native| {
                try writer.println("const {s}, const rest_{s} = try protocol_support.read_{s}({s});", .{ compareName, compareName, @tagName(native), restName });
                try writer.println("{s} = rest_{s};", .{ restName, compareName });
            },
            .mapper => |mapper| {
                try writer.println("const {s}, const rest_{s} = try protocol_support.read_{s}({s});", .{ compareName, compareName, @tagName(mapper.type), restName });
                try writer.println("{s} = rest_{s};", .{ restName, compareName });
            },
            .bitfield => |bitfield| {
                _ = compareTo;
                const id = writer.nextId();
                try writer.println("const packed_{}, const rest_{} = try protocol_support.read_packed_bits({s}, {});", .{ id, id, restName, bitfieldBits(bitfield.fields) });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("const {s} = packed_{};", .{ compareName, id });
            },
            .bitflags => |bitflags| {
                _ = compareTo;
                try writer.println("const {s}, const rest_{s} = try protocol_support.read_{s}({s});", .{ compareName, compareName, @tagName(bitflags.type), restName });
                try writer.println("{s} = rest_{s};", .{ restName, compareName });
            },
            .option => |option| {
                try writer.println("var {s}: i32 = -1;", .{compareName});
                const id = writer.nextId();
                try writer.println("const present_{}, const rest_{} = try protocol_support.read_bool({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (present_{}) {{", .{id});
                writer.indent();
                try codegenReadI32ComparePayload(option, types, writer, scope, restName, compareName);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .switch_ => |switch_| {
                try writer.println("var {s}: i32 = -1;", .{compareName});
                if (findCompareBinding(parent_bindings, comparePathBase(switch_.compareTo))) |binding| {
                    const switch_expr = try codegenSwitchCompareName(types, writer, scope, binding.type, binding.value_name, switch_.compareTo);
                    defer writer.allocator.free(switch_expr);
                    try writer.println("switch ({s}) {{", .{switch_expr});
                    writer.indent();
                    for (switch_.fields) |field| {
                        if (try switchCaseLabel(writer.allocator, binding.type, types, scope, field.name)) |label| {
                            defer writer.allocator.free(label);
                            try writer.println("{s} => {{", .{label});
                            writer.indent();
                            try codegenReadI32ComparePayload(&field.type, types, writer, scope, restName, compareName);
                            writer.unindent();
                            try writer.println("}},", .{});
                        }
                    }
                    try writer.println("else => {{", .{});
                    writer.indent();
                    try switch_.default.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                    writer.unindent();
                    try writer.println("}},", .{});
                    writer.unindent();
                    try writer.println("}}", .{});
                } else {
                    try actual.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget - 1);
                }
            },
            else => try actual.codegenAstSkipDepth(types, writer, scope, restName, budget),
        }
    }

    fn codegenAstSwitchSkip(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8, switch_: SwitchType, compareType: *const Type, compareName: []const u8, parent_bindings: []const CompareBinding, budget: usize) anyerror!void {
        _ = self;
        const switch_expr = try codegenSwitchCompareName(types, writer, scope, compareType, compareName, switch_.compareTo);
        defer writer.allocator.free(switch_expr);
        try writer.println("switch ({s}) {{", .{switch_expr});
        writer.indent();
        for (switch_.fields) |field| {
            if (try switchCaseLabel(writer.allocator, compareType, types, scope, field.name)) |label| {
                defer writer.allocator.free(label);
                try writer.println("{s} => {{", .{label});
                writer.indent();
                try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget);
                writer.unindent();
                try writer.println("}},", .{});
            }
        }
        if (!switchHasExhaustiveBoolCases(compareType, types, scope, switch_)) {
            try writer.println("else => {{", .{});
            writer.indent();
            try switch_.default.codegenAstSkipDepthWithCompares(types, writer, scope, restName, parent_bindings, budget);
            writer.unindent();
            try writer.println("}},", .{});
        }
        writer.unindent();
        try writer.println("}}", .{});
    }

    fn codegenAstWriteType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, depth: usize) anyerror!void {
        switch (self.*) {
            .reference => |reference| {
                if (isNamedWriteTarget(reference)) {
                    try codegenAstWriteNamedReferenceType(writer, reference, type_name, next_name, next_init);
                    return;
                }
            },
            else => {},
        }

        const actual = self.resolveAstWriteAlias(types, scope);
        switch (actual.*) {
            .container => |container| {
                try actual.codegenAstWriteContainerType(types, writer, scope, type_name, next_name, next_init, container.fields, depth);
            },
            .array => |array| try actual.codegenAstWriteArrayType(types, writer, scope, type_name, next_name, next_init, array, depth),
            .option => |option| try option.codegenAstWriteOptionType(types, writer, scope, type_name, next_name, next_init, depth),
            .registryEntryHolder => |holder| try actual.codegenAstWriteRegistryEntryHolderType(types, writer, scope, type_name, next_name, next_init, holder, depth),
            .registryEntryHolderSet => |set| try actual.codegenAstWriteRegistryEntryHolderSetType(types, writer, scope, type_name, next_name, next_init, set, depth),
            .switch_ => |switch_| {
                if (depth >= max_ast_write_depth and !actual.canExposeAstWriteSwitchAtDepth(types, scope, switch_) and !actual.canAstWritePastDepth(types, scope, 4)) {
                    return error.UnsupportedEncodedPayloadFallback;
                } else {
                    try actual.codegenAstWriteSwitchType(types, writer, scope, type_name, next_name, next_init, switch_, depth);
                }
            },
            else => try actual.codegenAstWriteLeafType(types, writer, scope, type_name, next_name, next_init),
        }
    }

    fn astWriteFieldInit(self: *const Type, types: *const Types, scope: Scope, next_init: WriteNextInit) WriteNextInit {
        const actual = self.resolveAstWriteAlias(types, scope);
        return switch (actual.*) {
            .array => next_init.arrayFieldInit(),
            else => next_init,
        };
    }

    fn codegenAstWriteContainerType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, fields: []Field, depth: usize) anyerror!void {
        _ = self;
        if (fields.len == 0) {
            try writer.println("pub const {s} = struct {{", .{type_name});
            writer.indent();
            try codegenWriteStateFields(writer, next_init);
            try writer.println("", .{});
            try writer.println("pub fn finish(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
            writer.indent();
            try writer.println("const rest = self.rest;", .{});
            try codegenWriteNextReturn(writer, next_init);
            writer.unindent();
            try writer.println("}}", .{});
            writer.unindent();
            try writer.println("}};", .{});
            try writer.println("", .{});
            return;
        }

        var current_name: []const u8 = try std.fmt.allocPrint(writer.allocator, "{s}", .{type_name});
        defer writer.allocator.free(current_name);
        for (0.., fields) |i, field| {
            const is_last = i + 1 == fields.len;
            const nested_name = try nestedWriteTypeName(writer.allocator, current_name, field.name);
            defer writer.allocator.free(nested_name);
            const after_name = if (is_last)
                try std.fmt.allocPrint(writer.allocator, "{s}", .{next_name})
            else
                try nestedWriteTypeName(writer.allocator, type_name, fields[i + 1].name);
            defer writer.allocator.free(after_name);
            const after_init = if (is_last) next_init else next_init.preserveForSibling();

            try writer.println("pub const {s} = struct {{", .{current_name});
            writer.indent();
            try codegenWriteStateFields(writer, next_init);
            try writer.println("", .{});
            const field_init = field.type.astWriteFieldInit(types, scope, after_init);
            try field.type.codegenAstWriteEntry(types, writer, scope, field.name, nested_name, after_name, field_init);
            writer.unindent();
            try writer.println("}};", .{});
            try writer.println("", .{});

            try field.type.codegenAstWriteType(types, writer, scope, nested_name, after_name, field_init, depth + 1);

            if (!is_last) {
                writer.allocator.free(current_name);
                current_name = try nestedWriteTypeName(writer.allocator, type_name, fields[i + 1].name);
            }
        }
    }

    fn codegenAstWriteEntry(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, field_name: []const u8, nested_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        switch (self.*) {
            .reference => |reference| {
                if (isNamedWriteTarget(reference)) {
                    try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                    writer.indent();
                    try writer.println("return .{{ .buffer = self.buffer, .rest = self.rest, .cont = {s}__continuation.init(self) }};", .{nested_name});
                    writer.unindent();
                    try writer.println("}}", .{});
                    return;
                }
            },
            else => {},
        }
        const actual = self.resolveAstWriteAlias(types, scope);
        switch (actual.*) {
            .container, .option, .switch_, .registryEntryHolder => {
                try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                writer.indent();
                try codegenWriteReturnCarrySelf(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .array => |array| {
                switch (array.count) {
                    .type => |countType| {
                        try writer.println("pub fn {f}(self: @This(), count: usize) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                        writer.indent();
                        try writer.println("var rest = self.rest;", .{});
                        try writer.println("rest = try protocol_support.write_count(rest, {s}, count);", .{try countType.codegenType()});
                        try codegenWriteReturnNewArray(writer, next_init, "rest", "count");
                        writer.unindent();
                        try writer.println("}}", .{});
                    },
                    .constant => |constant| {
                        try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                        writer.indent();
                        const count_expr = try std.fmt.allocPrint(writer.allocator, "{}", .{constant});
                        defer writer.allocator.free(count_expr);
                        try codegenWriteReturnNewArray(writer, next_init, "self.rest", count_expr);
                        writer.unindent();
                        try writer.println("}}", .{});
                    },
                    .field => {
                        try writer.println("pub fn {f}(self: @This(), count: usize) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                        writer.indent();
                        try codegenWriteReturnNewArray(writer, next_init, "self.rest", "count");
                        writer.unindent();
                        try writer.println("}}", .{});
                    },
                }
            },
            else => try actual.codegenAstWriteLeafEntry(types, writer, scope, field_name, next_name, next_init),
        }
    }

    fn codegenAstWriteLeafType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init);
        try writer.println("", .{});
        try self.codegenAstWriteLeafEntry(types, writer, scope, "value", next_name, next_init);
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});
    }

    fn codegenAstWriteLeafEntry(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, field_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        const actual = self.resolveAstWriteAlias(types, scope);
        switch (actual.*) {
            .native => |native| {
                if (native == .void) {
                    try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                } else if (native.hasDirectWrite()) {
                    try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), try native.codegenType(), next_name });
                } else {
                    try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                }
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                if (native.hasDirectWrite()) {
                    try codegenNativeWrite(native, writer, "rest");
                } else {
                    try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{});
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .pstring => |pstring| {
                try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_pstring(rest, field_value, {s});", .{try pstring.countType.codegenType()});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .buffer => |buffer| {
                try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                switch (buffer) {
                    .constant => try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{}),
                    .type => |countType| try writer.println("rest = try protocol_support.write_buffer_counted(rest, field_value, {s});", .{try countType.codegenType()}),
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitfield => |bitfield| {
                try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), try codegenBitfieldValueType(writer.allocator, bitfield.fields), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try codegenBitfieldWrite(bitfield.fields, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitflags => |bitflags| {
                try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), try codegenBitflagsValueType(writer.allocator, bitflags.flags), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try codegenBitflagsWrite(bitflags, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .mapper => |mapper| {
                try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), try mapper.type.codegenType(), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_{s}(rest, field_value);", .{@tagName(mapper.type)});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            else => {
                try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
        }
    }

    fn codegenAstWriteArrayType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, array: anytype, depth: usize) anyerror!void {
        _ = self;
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init.withRequiredArrayRemaining());
        try writer.println("", .{});
        const element = array.elementType.resolveAstWriteAlias(types, scope);
        if (element.isAstWriteScalar(types, scope)) {
            try element.codegenAstArrayElementMethod(types, writer, scope, type_name, next_init.elementForArray());
        } else if (array.elementType.isNamedWriteReference()) {
            const element_name = try std.fmt.allocPrint(writer.allocator, "{s}__element", .{type_name});
            defer writer.allocator.free(element_name);
            try writer.println("pub fn element(self: @This()) protocol_support.WriteError!{s} {{", .{element_name});
            writer.indent();
            try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
            try writer.println("return .{{ .buffer = self.buffer, .rest = self.rest, .cont = {s}__continuation.init(self) }};", .{element_name});
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
        } else if (depth >= max_ast_write_depth and !element.canAstWritePastDepth(types, scope, 4)) {
            return error.UnsupportedEncodedPayloadFallback;
        } else {
            const element_name = try std.fmt.allocPrint(writer.allocator, "{s}__element", .{type_name});
            defer writer.allocator.free(element_name);
            try writer.println("pub fn element(self: @This()) protocol_support.WriteError!{s} {{", .{element_name});
            writer.indent();
            try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
            try codegenWriteReturnCarrySelf(writer, next_init.withRequiredArrayRemaining());
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
        }
        try writer.println("pub fn finish(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
        writer.indent();
        try writer.println("if (self.remaining != 0) return error.MissingItems;", .{});
        try writer.println("const rest = self.rest;", .{});
        try codegenWriteNextReturn(writer, next_init);
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});
        if (array.elementType.isNamedWriteReference() or (!element.isAstWriteScalar(types, scope) and (depth < max_ast_write_depth or element.canAstWritePastDepth(types, scope, 4)))) {
            const element_name = try std.fmt.allocPrint(writer.allocator, "{s}__element", .{type_name});
            defer writer.allocator.free(element_name);
            try array.elementType.codegenAstWriteType(types, writer, scope, element_name, type_name, next_init.elementForArray(), depth + 1);
        }
    }

    fn codegenAstArrayElementMethod(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, array_name: []const u8, next_init: WriteNextInit) anyerror!void {
        const actual = self.resolveAstWriteAlias(types, scope);
        try actual.codegenAstWriteLeafEntry(types, writer, scope, "element", array_name, next_init);
        try writer.println("", .{});
    }

    fn codegenAstWriteOptionType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, depth: usize) anyerror!void {
        const actual = self.resolveAstWriteAlias(types, scope);
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init);
        try writer.println("", .{});
        try writer.println("pub fn none(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
        writer.indent();
        try writer.println("var rest = self.rest;", .{});
        try writer.println("rest = try protocol_support.write_bool(rest, false);", .{});
        try codegenWriteNextReturn(writer, next_init);
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
        if (actual.isAstWriteScalar(types, scope)) {
            try actual.codegenAstWriteOptionSomeScalar(types, writer, scope, next_name, next_init);
        } else if (actual.* == .array) {
            const array = actual.array;
            const array_init = next_init.arrayFieldInit();
            const value_name = try std.fmt.allocPrint(writer.allocator, "{s}__value", .{type_name});
            defer writer.allocator.free(value_name);
            switch (array.count) {
                .type => |countType| {
                    try writer.println("pub fn some(self: @This(), count: usize) protocol_support.WriteError!{s} {{", .{value_name});
                    writer.indent();
                    try writer.println("var rest = self.rest;", .{});
                    try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                    try writer.println("rest = try protocol_support.write_count(rest, {s}, count);", .{try countType.codegenType()});
                    try codegenWriteReturnNewArray(writer, array_init, "rest", "count");
                    writer.unindent();
                    try writer.println("}}", .{});
                },
                .constant => |constant| {
                    try writer.println("pub fn some(self: @This()) protocol_support.WriteError!{s} {{", .{value_name});
                    writer.indent();
                    const count_expr = try std.fmt.allocPrint(writer.allocator, "{}", .{constant});
                    defer writer.allocator.free(count_expr);
                    try writer.println("var rest = self.rest;", .{});
                    try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                    try codegenWriteReturnNewArray(writer, array_init, "rest", count_expr);
                    writer.unindent();
                    try writer.println("}}", .{});
                },
                .field => {
                    try writer.println("pub fn some(self: @This(), count: usize) protocol_support.WriteError!{s} {{", .{value_name});
                    writer.indent();
                    try writer.println("var rest = self.rest;", .{});
                    try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                    try codegenWriteReturnNewArray(writer, array_init, "rest", "count");
                    writer.unindent();
                    try writer.println("}}", .{});
                },
            }
        } else if (self.isNamedWriteReference()) {
            const value_name = try std.fmt.allocPrint(writer.allocator, "{s}__value", .{type_name});
            defer writer.allocator.free(value_name);
            try writer.println("pub fn some(self: @This()) protocol_support.WriteError!{s} {{", .{value_name});
            writer.indent();
            try writer.println("var rest = self.rest;", .{});
            try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
            try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .cont = {s}__continuation.init(self) }};", .{value_name});
            writer.unindent();
            try writer.println("}}", .{});
        } else if (depth >= max_ast_write_depth and !actual.canAstWritePastDepth(types, scope, 4)) {
            return error.UnsupportedEncodedPayloadFallback;
        } else {
            const value_name = try std.fmt.allocPrint(writer.allocator, "{s}__value", .{type_name});
            defer writer.allocator.free(value_name);
            try writer.println("pub fn some(self: @This()) protocol_support.WriteError!{s} {{", .{value_name});
            writer.indent();
            try writer.println("var rest = self.rest;", .{});
            try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
            try codegenWriteReturnCarryWithRest(writer, next_init, "rest");
            writer.unindent();
            try writer.println("}}", .{});
        }
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});
        if (self.isNamedWriteReference() or (!actual.isAstWriteScalar(types, scope) and (depth < max_ast_write_depth or actual.canAstWritePastDepth(types, scope, 4)))) {
            const value_name = try std.fmt.allocPrint(writer.allocator, "{s}__value", .{type_name});
            defer writer.allocator.free(value_name);
            const value_init = if (actual.* == .array) next_init.arrayFieldInit() else next_init;
            try self.codegenAstWriteType(types, writer, scope, value_name, next_name, value_init, depth + 1);
        }
    }

    fn codegenAstWriteOptionSomeScalar(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        const actual = self.resolveAstWriteAlias(types, scope);
        switch (actual.*) {
            .native => |native| {
                if (native == .void) {
                    try writer.println("pub fn some(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
                } else if (native.hasDirectWrite()) {
                    try writer.println("pub fn some(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try native.codegenType(), next_name });
                } else {
                    try writer.println("pub fn some(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{next_name});
                }
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                if (native.hasDirectWrite()) {
                    try codegenNativeWrite(native, writer, "rest");
                } else {
                    try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{});
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .pstring => |pstring| {
                try writer.println("pub fn some(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{next_name});
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try writer.println("rest = try protocol_support.write_pstring(rest, field_value, {s});", .{try pstring.countType.codegenType()});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .buffer => |buffer| {
                try writer.println("pub fn some(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{next_name});
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                switch (buffer) {
                    .constant => try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{}),
                    .type => |countType| try writer.println("rest = try protocol_support.write_buffer_counted(rest, field_value, {s});", .{try countType.codegenType()}),
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitfield => |bitfield| {
                try writer.println("pub fn some(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try codegenBitfieldValueType(writer.allocator, bitfield.fields), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try codegenBitfieldWrite(bitfield.fields, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitflags => |bitflags| {
                try writer.println("pub fn some(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try codegenBitflagsValueType(writer.allocator, bitflags.flags), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try codegenBitflagsWrite(bitflags, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .mapper => |mapper| {
                try writer.println("pub fn some(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try mapper.type.codegenType(), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try writer.println("rest = try protocol_support.write_{s}(rest, field_value);", .{@tagName(mapper.type)});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            else => unreachable,
        }
    }

    fn codegenAstWriteRegistryEntryHolderType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, holder: anytype, depth: usize) anyerror!void {
        _ = self;
        const data_name = try nestedWriteTypeName(writer.allocator, type_name, holder.otherwise.name);
        defer writer.allocator.free(data_name);

        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init);
        try writer.println("", .{});
        try writer.println("pub fn {f}(self: @This(), field_value: i32) protocol_support.WriteError!{s} {{", .{ idfmt(holder.baseName), next_name });
        writer.indent();
        try writer.println("var rest = self.rest;", .{});
        try writer.println("rest = try protocol_support.write_varint(rest, field_value);", .{});
        try codegenWriteNextReturn(writer, next_init);
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
        try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(holder.otherwise.name), data_name });
        writer.indent();
        try writer.println("var rest = self.rest;", .{});
        try writer.println("rest = try protocol_support.write_varint(rest, 0);", .{});
        try codegenWriteReturnCarryWithRest(writer, next_init, "rest");
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        try holder.otherwise.type.codegenAstWriteType(types, writer, scope, data_name, next_name, next_init, depth + 1);
    }

    fn codegenAstWriteRegistryEntryHolderSetType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, set: anytype, depth: usize) anyerror!void {
        _ = self;
        const base_name = try nestedWriteTypeName(writer.allocator, type_name, set.base.name);
        defer writer.allocator.free(base_name);
        const ids_name = try nestedWriteTypeName(writer.allocator, type_name, set.otherwise.name);
        defer writer.allocator.free(ids_name);

        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init);
        try writer.println("", .{});
        try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(set.base.name), base_name });
        writer.indent();
        try writer.println("var rest = self.rest;", .{});
        try writer.println("rest = try protocol_support.write_varint(rest, 0);", .{});
        try codegenWriteReturnCarryWithRest(writer, next_init, "rest");
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
        try writer.println("pub fn {f}(self: @This(), count: usize) protocol_support.WriteError!{s} {{", .{ idfmt(set.otherwise.name), ids_name });
        writer.indent();
        try writer.println("var rest = self.rest;", .{});
        try writer.println("rest = try protocol_support.write_count(rest, i32, count + 1);", .{});
        try codegenWriteReturnNewArray(writer, next_init, "rest", "count");
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        try set.base.type.codegenAstWriteType(types, writer, scope, base_name, next_name, next_init, depth + 1);
        try set.otherwise.type.codegenAstWriteArrayType(types, writer, scope, ids_name, next_name, next_init, .{ .count = ArrayCount{ .field = set.otherwise.name }, .elementType = set.otherwise.type }, depth + 1);
    }

    fn codegenAstWriteSwitchType(self: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, switch_: SwitchType, depth: usize) anyerror!void {
        _ = self;
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init);
        try writer.println("", .{});
        for (switch_.fields) |field| {
            const method_name = try switchCaseMethodName(writer.allocator, field.name);
            defer writer.allocator.free(method_name);
            const variant_name = try std.fmt.allocPrint(writer.allocator, "{s}__{s}", .{ type_name, method_name });
            defer writer.allocator.free(variant_name);
            try field.type.codegenAstWriteEntry(types, writer, scope, method_name, variant_name, next_name, next_init);
            try writer.println("", .{});
        }
        const default_name = try std.fmt.allocPrint(writer.allocator, "{s}__case_default", .{type_name});
        defer writer.allocator.free(default_name);
        try switch_.default.codegenAstWriteEntry(types, writer, scope, "case_default", default_name, next_name, next_init);
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});
        for (switch_.fields) |field| {
            const method_name = try switchCaseMethodName(writer.allocator, field.name);
            defer writer.allocator.free(method_name);
            const variant_name = try std.fmt.allocPrint(writer.allocator, "{s}__{s}", .{ type_name, method_name });
            defer writer.allocator.free(variant_name);
            try field.type.codegenAstWriteType(types, writer, scope, variant_name, next_name, next_init, depth + 1);
        }
        try switch_.default.codegenAstWriteType(types, writer, scope, default_name, next_name, next_init, depth + 1);
    }

    fn isAstWriteScalar(self: *const Type, types: *const Types, scope: Scope) bool {
        const actual = self.resolveAstWriteAlias(types, scope);
        return switch (actual.*) {
            .native, .pstring, .buffer, .mapper, .bitfield, .bitflags => true,
            else => false,
        };
    }

    fn canAstWritePastDepth(self: *const Type, types: *const Types, scope: Scope, budget: usize) bool {
        switch (self.*) {
            .reference => |reference| if (isNamedWriteTarget(reference)) return true,
            else => {},
        }
        const actual = self.resolveAstWriteAlias(types, scope);
        if (actual.isAstWriteScalar(types, scope)) return true;
        if (budget == 0) return false;
        return switch (actual.*) {
            .container => |container| blk: {
                for (container.fields) |field| {
                    if (!field.type.canAstWritePastDepth(types, scope, budget - 1)) break :blk false;
                }
                break :blk true;
            },
            .option => |option| option.canAstWritePastDepth(types, scope, budget - 1),
            .array => |array| array.elementType.canAstWritePastDepth(types, scope, budget - 1),
            .registryEntryHolder => |holder| holder.otherwise.type.canAstWritePastDepth(types, scope, budget - 1),
            .switch_ => |switch_| blk: {
                for (switch_.fields) |field| {
                    if (!field.type.canAstWritePastDepth(types, scope, budget - 1)) break :blk false;
                }
                break :blk switch_.default.canAstWritePastDepth(types, scope, budget - 1);
            },
            else => false,
        };
    }

    fn canExposeAstWriteSwitchAtDepth(self: *const Type, types: *const Types, scope: Scope, switch_: SwitchType) bool {
        _ = self;
        if (switch_.fields.len == 1 and std.mem.eql(u8, switch_.fields[0].name, "0")) {
            const zero_case = switch_.fields[0].type.resolveAstWriteAlias(types, scope);
            return switch (zero_case.*) {
                .native => |native| native == .void,
                else => false,
            };
        }
        return false;
    }

    fn canAstViewPastDepth(self: *const Type, types: *const Types, scope: Scope, budget: usize) bool {
        switch (self.*) {
            .reference => |reference| if (isNamedWriteTarget(reference)) return true,
            else => {},
        }
        const actual = self.resolveAstWriteAlias(types, scope);
        if (actual.codegenAstIsScalar(types, scope)) return true;
        if (budget == 0) return false;
        return switch (actual.*) {
            .container => |container| blk: {
                for (container.fields) |field| {
                    if (!field.type.canAstViewPastDepth(types, scope, budget - 1)) break :blk false;
                }
                break :blk true;
            },
            .option => |option| option.canAstViewPastDepth(types, scope, budget - 1),
            .array => |array| array.elementType.canAstViewPastDepth(types, scope, budget - 1),
            .registryEntryHolder => |holder| holder.otherwise.type.canAstViewPastDepth(types, scope, budget - 1),
            .switch_ => |switch_| blk: {
                for (switch_.fields) |field| {
                    if (!field.type.canAstViewPastDepth(types, scope, budget - 1)) break :blk false;
                }
                break :blk switch_.default.canAstViewPastDepth(types, scope, budget - 1);
            },
            else => false,
        };
    }

    fn canAstReadCompareValue(self: *const Type, types: *const Types, scope: Scope) bool {
        const actual = self.resolveAstWriteAlias(types, scope);
        return switch (actual.*) {
            .native, .mapper, .bitfield, .bitflags => true,
            .option => |option| canReadI32ComparePayload(option, types, scope),
            .switch_ => |switch_| canReadI32CompareSwitchPayload(switch_, types, scope),
            else => false,
        };
    }

    fn resolveAstWriteAlias(self: *const Type, types: *const Types, scope: Scope) *const Type {
        switch (self.*) {
            .reference => |reference| return resolveAlias(types, scope, reference) orelse self,
            else => return self,
        }
    }

    fn isNamedWriteReference(self: *const Type) bool {
        return switch (self.*) {
            .reference => |reference| isNamedWriteTarget(reference),
            else => false,
        };
    }

    fn hasAstViewAccessor(self: *const Type, types: *const Types, scope: Scope, name: []const u8) bool {
        const actual = self.resolveAstWriteAlias(types, scope);
        return switch (actual.*) {
            .container => |container| blk: {
                for (container.fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn typeNeedsCompareBinding(self: *const Type, types: *const Types, scope: Scope, name: []const u8, budget: usize) bool {
        if (budget == 0) return false;
        switch (self.*) {
            .reference => |reference| if (isNamedWriteTarget(reference)) return false,
            else => {},
        }
        const actual = self.resolveAstWriteAlias(types, scope);
        return switch (actual.*) {
            .switch_ => |switch_| blk: {
                if (std.mem.eql(u8, comparePathBase(switch_.compareTo), name)) break :blk true;
                for (switch_.fields) |field| {
                    if (field.type.typeNeedsCompareBinding(types, scope, name, budget - 1)) break :blk true;
                }
                break :blk switch_.default.typeNeedsCompareBinding(types, scope, name, budget - 1);
            },
            .container => |container| blk: {
                for (container.fields) |field| {
                    if (field.type.typeNeedsCompareBinding(types, scope, name, budget - 1)) break :blk true;
                }
                break :blk false;
            },
            .array => |array| array.elementType.typeNeedsCompareBinding(types, scope, name, budget - 1),
            .option => |option| option.typeNeedsCompareBinding(types, scope, name, budget - 1),
            .registryEntryHolder => |holder| holder.otherwise.type.typeNeedsCompareBinding(types, scope, name, budget - 1),
            .registryEntryHolderSet => |set| set.base.type.typeNeedsCompareBinding(types, scope, name, budget - 1) or set.otherwise.type.typeNeedsCompareBinding(types, scope, name, budget - 1),
            else => false,
        };
    }
};

fn findPreviousField(fields: []const Field, end: usize, name: []const u8) ?usize {
    var i = end;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, fields[i].name, name)) return i;
    }
    return null;
}

fn codegenAstSkipFields(types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8, fields: []const Field, parent_bindings: []const CompareBinding, budget: usize) anyerror!void {
    var compare_names = try writer.allocator.alloc(?[]const u8, fields.len);
    defer {
        for (compare_names) |name| {
            if (name) |value| writer.allocator.free(value);
        }
        writer.allocator.free(compare_names);
    }
    @memset(compare_names, null);
    var bindings = try std.ArrayList(CompareBinding).initCapacity(writer.allocator, parent_bindings.len);
    defer bindings.deinit(writer.allocator);
    try bindings.appendSlice(writer.allocator, parent_bindings);

    for (0.., fields) |i, field| {
        switch (field.type) {
            .switch_ => |switch_| {
                if ((fieldFeedsLaterSwitch(fields, i) or fieldFeedsLaterFieldCountArray(fields, i) or fieldFeedsLaterView(fields, i, types, scope)) and field.type.canAstReadCompareValue(types, scope)) {
                    const compare_name = try std.fmt.allocPrint(writer.allocator, "skip_compare_{}", .{writer.nextId()});
                    compare_names[i] = compare_name;
                    const compare_to = laterSwitchCompareForField(fields, i) orelse field.name;
                    try field.type.codegenAstReadCompareValue(types, writer, scope, restName, compare_name, compare_to, bindings.items, budget - 1);
                    try bindings.append(writer.allocator, .{ .name = field.name, .type = &fields[i].type, .value_name = compare_name });
                } else {
                    if (findPreviousCompareField(fields, i, switch_.compareTo)) |compare_index| {
                        if (compare_names[compare_index]) |compare_name| {
                            try field.type.codegenAstSwitchSkip(types, writer, scope, restName, switch_, &fields[compare_index].type, compare_name, bindings.items, budget - 1);
                        } else {
                            try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                        }
                    } else if (findCompareBinding(bindings.items, comparePathBase(switch_.compareTo))) |binding| {
                        try field.type.codegenAstSwitchSkip(types, writer, scope, restName, switch_, binding.type, binding.value_name, bindings.items, budget - 1);
                    } else {
                        try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                    }
                }
            },
            .array => |array| {
                if (array.count == .field) {
                    if (findPreviousField(fields, i, array.count.field)) |count_index| {
                        if (compare_names[count_index]) |count_name| {
                            try writer.println("for (0..@intCast({s})) |_| {{", .{count_name});
                            writer.indent();
                            try array.elementType.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                            writer.unindent();
                            try writer.println("}}", .{});
                        } else {
                            try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                        }
                    } else {
                        try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                    }
                } else {
                    try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                }
            },
            else => {
                if ((fieldFeedsLaterSwitch(fields, i) or fieldFeedsLaterFieldCountArray(fields, i) or fieldFeedsLaterView(fields, i, types, scope)) and field.type.canAstReadCompareValue(types, scope)) {
                    const compare_name = try std.fmt.allocPrint(writer.allocator, "skip_compare_{}", .{writer.nextId()});
                    compare_names[i] = compare_name;
                    const compare_to = laterSwitchCompareForField(fields, i) orelse field.name;
                    try field.type.codegenAstReadCompareValue(types, writer, scope, restName, compare_name, compare_to, bindings.items, budget - 1);
                    try bindings.append(writer.allocator, .{ .name = field.name, .type = &fields[i].type, .value_name = compare_name });
                } else {
                    try field.type.codegenAstSkipDepthWithCompares(types, writer, scope, restName, bindings.items, budget - 1);
                }
            },
        }
    }
}

fn findPreviousCompareField(fields: []const Field, end: usize, compareTo: []const u8) ?usize {
    const base = comparePathBase(compareTo);
    return findPreviousField(fields, end, base);
}

fn fieldFeedsLaterSwitch(fields: []const Field, index: usize) bool {
    for (fields[index + 1 ..]) |field| {
        switch (field.type) {
            .switch_ => |switch_| if (comparePathMatchesField(switch_.compareTo, fields[index].name)) return true,
            else => {},
        }
    }
    return false;
}

fn fieldFeedsLaterFieldCountArray(fields: []const Field, index: usize) bool {
    for (fields[index + 1 ..]) |field| {
        switch (field.type) {
            .array => |array| switch (array.count) {
                .field => |count_field| if (std.mem.eql(u8, count_field, fields[index].name)) return true,
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn fieldFeedsLaterView(fields: []const Field, index: usize, types: *const Types, scope: Scope) bool {
    for (fields[index + 1 ..]) |field| {
        if (field.type.typeNeedsCompareBinding(types, scope, fields[index].name, 16)) return true;
    }
    return false;
}

fn laterSwitchCompareForField(fields: []const Field, index: usize) ?[]const u8 {
    for (fields[index + 1 ..]) |field| {
        switch (field.type) {
            .switch_ => |switch_| if (comparePathMatchesField(switch_.compareTo, fields[index].name)) return switch_.compareTo,
            else => {},
        }
    }
    return null;
}

fn findCompareBinding(bindings: []const CompareBinding, name: []const u8) ?CompareBinding {
    var i = bindings.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, bindings[i].name, name)) return bindings[i];
    }
    return null;
}

fn removeCompareBindingsByName(bindings: *std.ArrayList(CompareBinding), name: []const u8) void {
    var i: usize = 0;
    while (i < bindings.items.len) {
        if (std.mem.eql(u8, bindings.items[i].name, name)) {
            _ = bindings.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn filterBindingsForType(allocator: std.mem.Allocator, typ: *const Type, types: *const Types, scope: Scope, bindings: []const CompareBinding) ![]CompareBinding {
    var result = try std.ArrayList(CompareBinding).initCapacity(allocator, bindings.len);
    defer result.deinit(allocator);
    for (0.., bindings) |i, binding| {
        var shadowed = false;
        for (bindings[i + 1 ..]) |later| {
            if (std.mem.eql(u8, later.name, binding.name) and typ.typeNeedsCompareBinding(types, scope, later.name, 16)) {
                shadowed = true;
                break;
            }
        }
        if (shadowed) continue;
        if (typ.typeNeedsCompareBinding(types, scope, binding.name, 16)) {
            try result.append(allocator, binding);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn compareBindingFieldName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "compare__{s}", .{sanitized});
}

fn compareBindingStorageType(binding: CompareBinding, types: *const Types, scope: Scope) ![]const u8 {
    const actual = binding.type.resolveAstWriteAlias(types, scope);
    return switch (actual.*) {
        .native => |native| try native.codegenType(),
        .mapper => |mapper| try mapper.type.codegenType(),
        .bitfield => "u64",
        .bitflags => |bitflags| try bitflags.type.codegenType(),
        .option, .switch_ => "i32",
        else => "u64",
    };
}

fn printViewInitializer(writer: *IndentedWriter, buffer_expr: []const u8, remaining_expr: ?[]const u8, bindings: []const CompareBinding) !void {
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("return .{{ .buffer = {s}", .{buffer_expr});
    if (remaining_expr) |remaining| {
        try writer.writer.print(", .remaining = {s}", .{remaining});
    }
    for (bindings) |binding| {
        const field_name = try compareBindingFieldName(writer.allocator, binding.name);
        defer writer.allocator.free(field_name);
        try writer.writer.print(", .{s} = {s}", .{ field_name, binding.value_name });
    }
    try writer.writer.print(" }};\n", .{});
}

fn printIteratorInitializer(writer: *IndentedWriter, rest_expr: []const u8, remaining_expr: []const u8, bindings: []const CompareBinding) !void {
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("return .{{ .rest = {s}, .remaining = {s}", .{ rest_expr, remaining_expr });
    for (bindings) |binding| {
        const field_name = try compareBindingFieldName(writer.allocator, binding.name);
        defer writer.allocator.free(field_name);
        try writer.writer.print(", .{s} = self.{s}", .{ field_name, field_name });
    }
    try writer.writer.print(" }};\n", .{});
}

fn comparePathTrim(compareTo: []const u8) []const u8 {
    var rest = compareTo;
    while (std.mem.startsWith(u8, rest, "../")) {
        rest = rest[3..];
    }
    return rest;
}

fn comparePathBase(compareTo: []const u8) []const u8 {
    const rest = comparePathTrim(compareTo);
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| return rest[0..slash];
    return rest;
}

fn comparePathMember(compareTo: []const u8) ?[]const u8 {
    const rest = comparePathTrim(compareTo);
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[slash + 1 ..];
}

fn comparePathMatchesField(compareTo: []const u8, fieldName: []const u8) bool {
    return std.mem.eql(u8, comparePathBase(compareTo), fieldName);
}

fn switchCaseLabel(allocator: std.mem.Allocator, compareType: *const Type, types: *const Types, scope: Scope, fieldName: []const u8) !?[]const u8 {
    const actual = compareType.resolveAstWriteAlias(types, scope);
    switch (actual.*) {
        .mapper => |mapper| {
            for (mapper.mappings) |mapping| {
                if (std.mem.eql(u8, mapping.name, fieldName)) {
                    return try std.fmt.allocPrint(allocator, "{}", .{mapping.value});
                }
            }
            return null;
        },
        .native => |native| {
            if (native == .bool) {
                if (std.mem.eql(u8, fieldName, "true")) return try allocator.dupe(u8, "true");
                if (std.mem.eql(u8, fieldName, "false")) return try allocator.dupe(u8, "false");
                return null;
            }
            const value = std.fmt.parseInt(i64, fieldName, 0) catch return null;
            return try std.fmt.allocPrint(allocator, "{}", .{value});
        },
        .bitfield => {
            const value = std.fmt.parseInt(i64, fieldName, 0) catch return null;
            return try std.fmt.allocPrint(allocator, "{}", .{value});
        },
        .bitflags => {
            if (std.mem.eql(u8, fieldName, "true")) return try allocator.dupe(u8, "true");
            if (std.mem.eql(u8, fieldName, "false")) return try allocator.dupe(u8, "false");
            return null;
        },
        .option => |option| return switchCaseLabel(allocator, option, types, scope, fieldName),
        .switch_ => {
            const value = std.fmt.parseInt(i64, fieldName, 0) catch return null;
            return try std.fmt.allocPrint(allocator, "{}", .{value});
        },
        else => return null,
    }
}

fn canReadNativeI32ComparePayload(native: NativeType) bool {
    return switch (native) {
        .varint,
        .u8,
        .u16,
        .i8,
        .i16,
        .i32,
        .bool,
        => true,
        else => false,
    };
}

fn canReadI32ComparePayload(typ: *const Type, types: *const Types, scope: Scope) bool {
    switch (typ.*) {
        .reference => |reference| {
            if (resolveNativeAlias(types, scope, reference)) |native| return canReadNativeI32ComparePayload(native);
        },
        else => {},
    }

    const actual = typ.resolveAstWriteAlias(types, scope);
    return switch (actual.*) {
        .native => |native| canReadNativeI32ComparePayload(native),
        .mapper => |mapper| canReadNativeI32ComparePayload(mapper.type),
        .option => |option| canReadI32ComparePayload(option, types, scope),
        .switch_ => false,
        else => false,
    };
}

fn canReadI32CompareSwitchPayload(switch_: SwitchType, types: *const Types, scope: Scope) bool {
    for (switch_.fields) |field| {
        if (!canReadI32ComparePayload(&field.type, types, scope)) return false;
    }
    return true;
}

fn codegenReadNativeI32ComparePayload(native: NativeType, writer: *IndentedWriter, restName: []const u8, compareName: []const u8) !void {
    const id = writer.nextId();
    try writer.println("const compare_value_{}, const compare_rest_{} = try protocol_support.read_{s}({s});", .{ id, id, @tagName(native), restName });
    try writer.println("{s} = compare_rest_{};", .{ restName, id });
    if (native == .bool) {
        try writer.println("{s} = @intFromBool(compare_value_{});", .{ compareName, id });
    } else {
        try writer.println("{s} = @intCast(compare_value_{});", .{ compareName, id });
    }
}

fn codegenReadI32ComparePayload(typ: *const Type, types: *const Types, writer: *IndentedWriter, scope: Scope, restName: []const u8, compareName: []const u8) anyerror!void {
    switch (typ.*) {
        .reference => |reference| {
            if (resolveNativeAlias(types, scope, reference)) |native| {
                if (canReadNativeI32ComparePayload(native)) {
                    try codegenReadNativeI32ComparePayload(native, writer, restName, compareName);
                } else {
                    try typ.codegenAstSkipDepthWithCompares(types, writer, scope, restName, &.{}, 8);
                }
                return;
            }
        },
        else => {},
    }

    const actual = typ.resolveAstWriteAlias(types, scope);
    switch (actual.*) {
        .native => |native| {
            if (canReadNativeI32ComparePayload(native)) {
                try codegenReadNativeI32ComparePayload(native, writer, restName, compareName);
            } else {
                try actual.codegenAstSkipDepthWithCompares(types, writer, scope, restName, &.{}, 8);
            }
        },
        .mapper => |mapper| {
            if (canReadNativeI32ComparePayload(mapper.type)) {
                try codegenReadNativeI32ComparePayload(mapper.type, writer, restName, compareName);
            } else {
                try actual.codegenAstSkipDepthWithCompares(types, writer, scope, restName, &.{}, 8);
            }
        },
        .option => |option| {
            const id = writer.nextId();
            try writer.println("const compare_present_{}, const compare_rest_{} = try protocol_support.read_bool({s});", .{ id, id, restName });
            try writer.println("{s} = compare_rest_{};", .{ restName, id });
            try writer.println("if (compare_present_{}) {{", .{id});
            writer.indent();
            try codegenReadI32ComparePayload(option, types, writer, scope, restName, compareName);
            writer.unindent();
            try writer.println("}}", .{});
        },
        .switch_ => try actual.codegenAstSkipDepthWithCompares(types, writer, scope, restName, &.{}, 8),
        else => try actual.codegenAstSkipDepthWithCompares(types, writer, scope, restName, &.{}, 8),
    }
}

fn codegenSwitchCompareName(types: *const Types, writer: *IndentedWriter, scope: Scope, compareType: *const Type, compareName: []const u8, compareTo: []const u8) ![]const u8 {
    const actual = compareType.resolveAstWriteAlias(types, scope);
    const member = comparePathMember(compareTo) orelse return try writer.allocator.dupe(u8, compareName);
    switch (actual.*) {
        .bitfield => |bitfield| {
            const field = bitfieldFieldByName(bitfield.fields, member) orelse return try writer.allocator.dupe(u8, compareName);
            const name = try std.fmt.allocPrint(writer.allocator, "switch_compare_{}", .{writer.nextId()});
            try printIndent(writer.writer, writer.level);
            if (field.type.size == 1 and !field.type.signed) {
                try writer.writer.print("const {s}: u1 = @intFromBool(", .{name});
                try codegenBitfieldMemberValue(bitfield.fields, writer, try writer.allocator.dupe(u8, compareName), member);
                try writer.writer.print(");\n", .{});
            } else {
                try writer.writer.print("const {s} = ", .{name});
                try codegenBitfieldMemberValue(bitfield.fields, writer, try writer.allocator.dupe(u8, compareName), member);
                try writer.writer.print(";\n", .{});
            }
            return name;
        },
        .bitflags => |bitflags| {
            const flag_index = bitflagIndex(bitflags.flags, member) orelse return try writer.allocator.dupe(u8, compareName);
            const name = try std.fmt.allocPrint(writer.allocator, "switch_compare_{}", .{writer.nextId()});
            try writer.println("const {s} = ({s} & @as({s}, {})) != 0;", .{ name, compareName, try bitflags.type.codegenType(), @as(u64, 1) << @intCast(flag_index) });
            return name;
        },
        else => return try writer.allocator.dupe(u8, compareName),
    }
}

fn switchHasExhaustiveBoolCases(compareType: *const Type, types: *const Types, scope: Scope, switch_: SwitchType) bool {
    const actual = compareType.resolveAstWriteAlias(types, scope);
    if (actual.* != .native or actual.native != .bool) return false;

    var has_true = false;
    var has_false = false;
    for (switch_.fields) |field| {
        if (std.mem.eql(u8, field.name, "true")) has_true = true;
        if (std.mem.eql(u8, field.name, "false")) has_false = true;
    }
    return has_true and has_false;
}

fn resolveAlias(types: *const Types, scope: Scope, reference: []const u8) ?*const Type {
    _ = types;
    if (scope.inner) |inner| {
        if (inner.types.getPtr(reference)) |found| return found;
    }
    if (scope.outer.types.getPtr(reference)) |found| return found;
    return null;
}

fn resolveNativeAlias(types: *const Types, scope: Scope, reference: []const u8) ?NativeType {
    const referenced = if (scope.inner) |inner| inner.types.get(reference) orelse scope.outer.types.get(reference) else scope.outer.types.get(reference);
    if (referenced) |r| switch (r) {
        .native => |native| return native,
        .reference => |next| return resolveNativeAlias(types, scope, next),
        else => {},
    };
    return null;
}

fn codegenAstNativeReturn(native: NativeType, writer: *IndentedWriter) !void {
    if (native == .void) {
        try writer.println("return {{}};", .{});
    } else {
        const id = writer.nextId();
        try writer.println("const field_value_{}, _ = try protocol_support.read_{s}(rest);", .{ id, @tagName(native) });
        try writer.println("return field_value_{};", .{id});
    }
}

fn codegenAstReadScalarInto(types: *const Types, writer: *IndentedWriter, scope: Scope, typ: *const Type, rest_name: []const u8, value_name: []const u8) anyerror!void {
    switch (typ.*) {
        .reference => |reference| {
            if (resolveNativeAlias(types, scope, reference)) |native| {
                try codegenAstReadNativeScalarInto(native, writer, rest_name, value_name);
                return;
            }
        },
        else => {},
    }

    const actual = typ.resolveAstWriteAlias(types, scope);
    switch (actual.*) {
        .native => |native| try codegenAstReadNativeScalarInto(native, writer, rest_name, value_name),
        .pstring => |pstring| {
            try writer.println("const {s}, const after_{s} = try protocol_support.read_pstring({s}, {s});", .{ value_name, value_name, rest_name, try pstring.countType.codegenType() });
            try writer.println("{s} = after_{s};", .{ rest_name, value_name });
        },
        .mapper => |mapper| {
            try writer.println("const {s}, const after_{s} = try protocol_support.read_{s}({s});", .{ value_name, value_name, @tagName(mapper.type), rest_name });
            try writer.println("{s} = after_{s};", .{ rest_name, value_name });
        },
        .bitfield => |bitfield| {
            const id = writer.nextId();
            try writer.println("const packed_{}, const after_{} = try protocol_support.read_packed_bits({s}, {});", .{ id, id, rest_name, bitfieldBits(bitfield.fields) });
            try writer.println("{s} = after_{};", .{ rest_name, id });
            try printIndent(writer.writer, writer.level);
            try writer.writer.print("const {s}: Value = ", .{value_name});
            try codegenBitfieldValueLiteral(bitfield.fields, writer, try std.fmt.allocPrint(writer.allocator, "packed_{}", .{id}));
            try writer.writer.print(";\n", .{});
        },
        .bitflags => |bitflags| {
            const id = writer.nextId();
            try writer.println("const flags_{}, const after_{} = try protocol_support.read_{s}({s});", .{ id, id, @tagName(bitflags.type), rest_name });
            try writer.println("{s} = after_{};", .{ rest_name, id });
            try printIndent(writer.writer, writer.level);
            try writer.writer.print("const {s}: Value = ", .{value_name});
            try codegenBitflagsValueLiteral(bitflags, writer, try std.fmt.allocPrint(writer.allocator, "flags_{}", .{id}));
            try writer.writer.print(";\n", .{});
        },
        else => unreachable,
    }
}

fn codegenAstReadNativeScalarInto(native: NativeType, writer: *IndentedWriter, rest_name: []const u8, value_name: []const u8) !void {
    if (native == .void) {
        try writer.println("const {s} = {{}};", .{value_name});
        return;
    }
    try writer.println("const {s}, const after_{s} = try protocol_support.read_{s}({s});", .{ value_name, value_name, @tagName(native), rest_name });
    try writer.println("{s} = after_{s};", .{ rest_name, value_name });
}

fn resolveReference(reference: []const u8, parentContainer: ?*ResolvedContainer) !*ResolvedField {
    if (parentContainer) |pc| {
        for (0.., pc.fields) |i, field| {
            if (std.mem.eql(u8, field.name, reference)) {
                pc.fields[i].referenced = true;
                return &pc.fields[i];
            }
        }
    }
    return error.InvalidCompareTo;
}

const ResolvedField = struct {
    name: []const u8,
    type: *ResolvedType,
    referenced: bool = false,
    currentValue: ?i64 = null,
};

const ResolvedContainer = struct {
    fields: []ResolvedField,

    pub fn cursor(self: *const ResolvedContainer, cursors: *Cursors, i: usize) anyerror!CursorTree {
        if (self.fields[i].referenced) {
            switch (self.fields[i].type.*) {
                .mapper => |mapper| {
                    try cursors.pushName(self.fields[i].name);
                    var c = try cursors.allocateCursor();
                    cursors.popName();
                    const variants = try cursors.allocator.alloc(CursorVariant, mapper.mappings.len);
                    var tails = try std.ArrayList(*Cursor).initCapacity(cursors.allocator, 0);
                    for (0.., mapper.mappings) |j, mapping| {
                        self.fields[i].currentValue = mapping.value;
                        try cursors.pushName(mapping.name);
                        const nextTree = try self.cursor(cursors, i + 1);
                        cursors.popName();
                        switch (nextTree.tails) {
                            .one => |one| try tails.append(cursors.allocator, one),
                            .many => |many| try tails.appendSlice(cursors.allocator, many.items),
                        }
                        variants[j] = .{
                            .value = mapping.value,
                            .name = mapping.name,
                            .cursor = nextTree.head,
                        };
                    }
                    self.fields[i].currentValue = null;
                    const defaultNextTree = try self.cursor(cursors, i + 1);
                    switch (defaultNextTree.tails) {
                        .one => |one| try tails.append(cursors.allocator, one),
                        .many => |many| try tails.appendSlice(cursors.allocator, many.items),
                    }
                    c.kind = .{
                        .variants = .{
                            .readType = mapper.type,
                            .variants = variants,
                            .default = defaultNextTree.head,
                        },
                    };
                    return .{
                        .head = c,
                        .tails = .{ .many = tails },
                    };
                },
                else => {
                    const result = try cursors.allocateCursor();
                    result.kind = .{ .complex = .{ .type = self.fields[i].type, .next = null } };
                    return .{ .head = result, .tails = .{ .one = result } };
                },
            }
        } else {
            try cursors.pushName(self.fields[i].name);
            var cursorTree = try self.fields[i].type.cursor(cursors);
            cursors.popName();
            if (i + 1 < self.fields.len) {
                const next = try self.cursor(cursors, i + 1);
                try cursorTree.updateNext(next.head);
                cursorTree.tails = next.tails;
            }
            return cursorTree;
        }
    }

    fn codegenNestedWriteTypes(self: *const ResolvedContainer, writer: *IndentedWriter, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        if (self.fields.len == 0) {
            try writer.println("pub const {s} = struct {{", .{type_name});
            writer.indent();
            try codegenWriteStateFields(writer, next_init);
            try writer.println("", .{});
            try writer.println("pub fn finish(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
            writer.indent();
            try writer.println("const rest = self.rest;", .{});
            try codegenWriteNextReturn(writer, next_init);
            writer.unindent();
            try writer.println("}}", .{});
            writer.unindent();
            try writer.println("}};", .{});
            try writer.println("", .{});
            return;
        }

        var current_name: []const u8 = try std.fmt.allocPrint(writer.allocator, "{s}", .{type_name});
        defer writer.allocator.free(current_name);

        for (0.., self.fields) |i, field| {
            const field_nested_name = try nestedWriteTypeName(writer.allocator, current_name, field.name);
            defer writer.allocator.free(field_nested_name);
            const is_last = i + 1 == self.fields.len;
            const after_name = if (is_last)
                try std.fmt.allocPrint(writer.allocator, "{s}", .{next_name})
            else
                try nestedWriteTypeName(writer.allocator, type_name, self.fields[i + 1].name);
            defer writer.allocator.free(after_name);
            const after_init = if (is_last) next_init else next_init.preserveForSibling();
            const field_init = field.type.nestedWriteFieldInit(after_init);

            try writer.println("pub const {s} = struct {{", .{current_name});
            writer.indent();
            try codegenWriteStateFields(writer, next_init);
            try writer.println("", .{});
            try field.type.codegenNestedWriteEntry(writer, field.name, field_nested_name, after_name, field_init);
            writer.unindent();
            try writer.println("}};", .{});
            try writer.println("", .{});

            try field.type.codegenNestedWriteType(writer, field_nested_name, after_name, field_init);

            if (!is_last) {
                writer.allocator.free(current_name);
                current_name = try nestedWriteTypeName(writer.allocator, type_name, self.fields[i + 1].name);
            }
        }
    }
};

const ResolvedVariant = struct {
    value: []const u8,
    type: *ResolvedType,
};

const ResolvedType = union(enum) {
    todo,
    native: NativeType,
    container: ResolvedContainer,
    bitfield: struct { fields: []BitfieldField },
    bitflags: struct { type: NativeType, flags: []const []const u8 },
    array: struct { count: ArrayCount, elementType: *ResolvedType },
    pstring: struct { countType: NativeType },
    option: *ResolvedType,
    buffer: BufferCount,
    topBitSetTerminatedArray: *ResolvedType,
    entityMetadataLoop: struct { endVal: i64, type: *ResolvedType },
    registryEntryHolder: struct { baseName: []const u8, otherwise: ResolvedField },
    registryEntryHolderSet: struct { base: ResolvedField, otherwise: ResolvedField },
    switch_: struct {
        compareTo: *ResolvedField,
        variants: []ResolvedVariant,
        default: *ResolvedType,
    },
    mapper: struct { type: NativeType, mappings: []Mapping },

    pub fn cursor(self: *const ResolvedType, cursors: *Cursors) anyerror!CursorTree {
        switch (self.*) {
            .native => |native| {
                const result = try cursors.allocateCursor();
                result.kind = .{ .simple = .{ .readType = .{ .native = native }, .next = null } };
                return .{ .head = result, .tails = .{ .one = result } };
            },
            .container => |container| {
                if (container.fields.len == 0) {
                    const result = try cursors.allocateCursor();
                    result.kind = .{ .complex = .{ .type = self, .next = null } };
                    return .{ .head = result, .tails = .{ .one = result } };
                }
                return container.cursor(cursors, 0);
            },
            .pstring => |pstring| {
                const result = try cursors.allocateCursor();
                result.kind = .{ .simple = .{ .readType = .{ .pstring = pstring.countType }, .next = null } };
                return .{ .head = result, .tails = .{ .one = result } };
            },
            .bitfield => |bitfield| {
                const result = try cursors.allocateCursor();
                result.kind = .{ .simple = .{ .readType = .{ .bitfield = bitfield.fields }, .next = null } };
                return .{ .head = result, .tails = .{ .one = result } };
            },
            .bitflags => |bitflags| {
                const result = try cursors.allocateCursor();
                result.kind = .{ .simple = .{ .readType = .{ .bitflags = .{ .type = bitflags.type, .flags = bitflags.flags } }, .next = null } };
                return .{ .head = result, .tails = .{ .one = result } };
            },
            .array, .option, .buffer, .topBitSetTerminatedArray, .entityMetadataLoop, .registryEntryHolder, .registryEntryHolderSet => {
                const result = try cursors.allocateCursor();
                result.kind = .{ .complex = .{ .type = self, .next = null } };
                return .{ .head = result, .tails = .{ .one = result } };
            },
            .switch_ => |switch_| {
                switch (switch_.compareTo.type.*) {
                    .mapper => |mapper| {
                        if (switch_.compareTo.currentValue) |currentValue| {
                            const currentValueName = blk: {
                                for (mapper.mappings) |mapping| {
                                    if (mapping.value == currentValue) {
                                        break :blk mapping.name;
                                    }
                                }
                                unreachable;
                            };
                            for (switch_.variants) |variant| {
                                if (std.mem.eql(u8, variant.value, currentValueName)) {
                                    return variant.type.cursor(cursors);
                                }
                            }
                        }
                        return switch_.default.cursor(cursors);
                    },
                    else => {
                        const result = try cursors.allocateCursor();
                        result.kind = .{ .complex = .{ .type = self, .next = null } };
                        return .{ .head = result, .tails = .{ .one = result } };
                    },
                }
            },
            else => {
                const result = try cursors.allocateCursor();
                result.kind = .{ .complex = .{ .type = self, .next = null } };
                return .{ .head = result, .tails = .{ .one = result } };
            },
        }
    }

    pub fn codegenSkip(self: *const ResolvedType, writer: *IndentedWriter, restName: []const u8) anyerror!void {
        switch (self.*) {
            .native => |native| try codegenNativeSkip(native, writer, restName),
            .pstring => |pstring| {
                try writer.println("{s} = (try protocol_support.read_pstring({s}, {s}))[1];", .{ restName, restName, try pstring.countType.codegenType() });
            },
            .buffer => |buffer| switch (buffer) {
                .constant => |count| try writer.println("{s} = (try protocol_support.read_buffer_exact({s}, {}))[1];", .{ restName, restName, count }),
                .type => |countType| try writer.println("{s} = (try protocol_support.read_buffer_counted({s}, {s}))[1];", .{ restName, restName, try countType.codegenType() }),
            },
            .container => |container| {
                if (container.fields.len == 0) {
                    try writer.println("{s} = {s}[0..];", .{ restName, restName });
                    return;
                }
                for (container.fields) |field| {
                    try field.type.codegenSkip(writer, restName);
                }
            },
            .bitfield => |bitfield| {
                const byte_count = (bitfieldBits(bitfield.fields) + 7) / 8;
                try writer.println("{s} = (try protocol_support.read_buffer_exact({s}, {}))[1];", .{ restName, restName, byte_count });
            },
            .bitflags => |bitflags| try codegenNativeSkip(bitflags.type, writer, restName),
            .array => |array| {
                const count_id = try codegenArrayCountRead(array.count, writer, restName);
                try writer.println("for (0..@intCast(count_{})) |_| {{", .{count_id});
                writer.indent();
                try array.elementType.codegenSkip(writer, restName);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .option => |option| {
                const id = writer.nextId();
                try writer.println("const present_{}, const rest_{} = try protocol_support.read_bool({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (present_{}) {{", .{id});
                writer.indent();
                try option.codegenSkip(writer, restName);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .topBitSetTerminatedArray => |array| {
                try writer.println("while (true) {{", .{});
                writer.indent();
                const id = writer.nextId();
                try writer.println("const marker_{}, const rest_{} = try protocol_support.read_i8({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (marker_{} < 0) break;", .{id});
                try array.codegenSkip(writer, restName);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .entityMetadataLoop => |loop| {
                try writer.println("while (true) {{", .{});
                writer.indent();
                const id = writer.nextId();
                try writer.println("const marker_{}, const rest_{} = try protocol_support.read_u8({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (marker_{} == {}) break;", .{ id, loop.endVal });
                try loop.type.codegenSkip(writer, restName);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .registryEntryHolder => |holder| {
                const id = writer.nextId();
                try writer.println("const holder_{}, const rest_{} = try protocol_support.read_varint({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (holder_{} == 0) {{", .{id});
                writer.indent();
                try holder.otherwise.type.codegenSkip(writer, restName);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .registryEntryHolderSet => |set| {
                const id = writer.nextId();
                try writer.println("const registry_entry_holder_set_count_{}, const rest_{} = try protocol_support.read_varint({s});", .{ id, id, restName });
                try writer.println("{s} = rest_{};", .{ restName, id });
                try writer.println("if (registry_entry_holder_set_count_{} == 0) {{", .{id});
                writer.indent();
                try set.base.type.codegenSkip(writer, restName);
                writer.unindent();
                try writer.println("}} else {{", .{});
                writer.indent();
                try writer.println("for (0..@intCast(registry_entry_holder_set_count_{} - 1)) |_| {{", .{id});
                writer.indent();
                try set.otherwise.type.codegenSkip(writer, restName);
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}}", .{});
            },
            .switch_ => |switch_| {
                _ = switch_;
                try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName });
            },
            .mapper => |mapper| try codegenNativeSkip(mapper.type, writer, restName),
            .todo => try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName }),
        }
    }

    fn codegenNestedWriteEntry(self: *const ResolvedType, writer: *IndentedWriter, field_name: []const u8, nested_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        switch (self.*) {
            .container => {
                try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                writer.indent();
                try codegenWriteReturnCarrySelf(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .array => |array| {
                switch (array.count) {
                    .type => |countType| {
                        try writer.println("pub fn {f}(self: @This(), count: usize) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                        writer.indent();
                        try writer.println("var rest = self.rest;", .{});
                        try writer.println("rest = try protocol_support.write_count(rest, {s}, count);", .{try countType.codegenType()});
                        try codegenWriteReturnNewArray(writer, next_init, "rest", "count");
                        writer.unindent();
                        try writer.println("}}", .{});
                    },
                    .constant => |constant| {
                        try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                        writer.indent();
                        const count_expr = try std.fmt.allocPrint(writer.allocator, "{}", .{constant});
                        defer writer.allocator.free(count_expr);
                        try codegenWriteReturnNewArray(writer, next_init, "self.rest", count_expr);
                        writer.unindent();
                        try writer.println("}}", .{});
                    },
                    .field => {
                        try writer.println("pub fn {f}(self: @This(), count: usize) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                        writer.indent();
                        try codegenWriteReturnNewArray(writer, next_init, "self.rest", "count");
                        writer.unindent();
                        try writer.println("}}", .{});
                    },
                }
            },
            .option => {
                try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                writer.indent();
                try codegenWriteReturnCarrySelf(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .switch_ => {
                try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), nested_name });
                writer.indent();
                try codegenWriteReturnCarrySelf(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .buffer => |buffer| {
                try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                switch (buffer) {
                    .constant => try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{}),
                    .type => |countType| try writer.println("rest = try protocol_support.write_buffer_counted(rest, field_value, {s});", .{try countType.codegenType()}),
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .native, .pstring, .mapper, .bitfield, .bitflags => try self.codegenNestedWriteScalarEntry(writer, field_name, nested_name, next_name, next_init),
            else => {
                try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
        }
    }

    fn codegenNestedWriteScalarEntry(self: *const ResolvedType, writer: *IndentedWriter, field_name: []const u8, nested_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        switch (self.*) {
            .native => |native| {
                if (native == .void) {
                    try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                } else {
                    try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), try native.codegenType(), next_name });
                }
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try codegenNativeWrite(native, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .pstring => |pstring| {
                try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_pstring(rest, field_value, {s});", .{try pstring.countType.codegenType()});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .mapper => |mapper| {
                const variant_name = nested_name;
                try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), variant_name });
                writer.indent();
                try codegenWriteReturnCarrySelf(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                try writer.println("", .{});
                try writer.println("pub const {s} = struct {{", .{variant_name});
                writer.indent();
                try codegenWriteStateFields(writer, next_init);
                try writer.println("", .{});
                for (mapper.mappings) |mapping| {
                    try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(mapping.name), next_name });
                    writer.indent();
                    try writer.println("var rest = self.rest;", .{});
                    try writer.println("rest = try protocol_support.write_{s}(rest, {});", .{ @tagName(mapper.type), mapping.value });
                    try codegenWriteNextReturn(writer, next_init);
                    writer.unindent();
                    try writer.println("}}", .{});
                    try writer.println("", .{});
                }
                try writer.println("pub fn raw(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try mapper.type.codegenType(), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_{s}(rest, field_value);", .{@tagName(mapper.type)});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}};", .{});
            },
            .buffer => |buffer| {
                try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                switch (buffer) {
                    .constant => try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{}),
                    .type => |countType| try writer.println("rest = try protocol_support.write_buffer_counted(rest, field_value, {s});", .{try countType.codegenType()}),
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitfield => |bitfield| {
                try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), try codegenBitfieldValueType(writer.allocator, bitfield.fields), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try codegenBitfieldWrite(bitfield.fields, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitflags => |bitflags| {
                try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ idfmt(field_name), try codegenBitflagsValueType(writer.allocator, bitflags.flags), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try codegenBitflagsWrite(bitflags, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            else => unreachable,
        }
    }

    fn codegenNestedWriteType(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        switch (self.*) {
            .container => |container| try container.codegenNestedWriteTypes(writer, type_name, next_name, next_init),
            .array => |array| try self.codegenArrayWriteType(writer, type_name, next_name, next_init, array),
            .option => |option| try option.codegenOptionWriteType(writer, type_name, next_name, next_init),
            .switch_ => |switch_| try self.codegenSwitchWriteType(writer, type_name, next_name, next_init, switch_),
            else => {},
        }
    }

    fn nestedWriteFieldInit(self: *const ResolvedType, next_init: WriteNextInit) WriteNextInit {
        return switch (self.*) {
            .array => next_init.arrayFieldInit(),
            else => next_init,
        };
    }

    fn codegenSwitchWriteType(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, switch_: anytype) anyerror!void {
        _ = self;
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init);
        try writer.println("", .{});

        for (switch_.variants) |variant| {
            const method_name = try switchCaseMethodName(writer.allocator, variant.value);
            defer writer.allocator.free(method_name);
            const variant_type_name = try std.fmt.allocPrint(writer.allocator, "{s}__{s}", .{ type_name, method_name });
            defer writer.allocator.free(variant_type_name);
            try variant.type.codegenNestedWriteEntry(writer, method_name, variant_type_name, next_name, next_init);
            try writer.println("", .{});
        }

        const default_type_name = try std.fmt.allocPrint(writer.allocator, "{s}__case_default", .{type_name});
        defer writer.allocator.free(default_type_name);
        try switch_.default.codegenNestedWriteEntry(writer, "case_default", default_type_name, next_name, next_init);
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        for (switch_.variants) |variant| {
            const method_name = try switchCaseMethodName(writer.allocator, variant.value);
            defer writer.allocator.free(method_name);
            const variant_type_name = try std.fmt.allocPrint(writer.allocator, "{s}__{s}", .{ type_name, method_name });
            defer writer.allocator.free(variant_type_name);
            try variant.type.codegenNestedWriteType(writer, variant_type_name, next_name, next_init);
        }
        try switch_.default.codegenNestedWriteType(writer, default_type_name, next_name, next_init);
    }

    fn codegenArrayWriteType(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit, array: anytype) anyerror!void {
        _ = self;
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init.withRequiredArrayRemaining());
        try writer.println("", .{});
        if (array.elementType.isNestedWriteScalar()) {
            try array.elementType.codegenArrayElementScalarMethod(writer, type_name, next_init.elementForArray());
        } else {
            const element_name = try std.fmt.allocPrint(writer.allocator, "{s}__element", .{type_name});
            defer writer.allocator.free(element_name);
            try writer.println("pub fn element(self: @This()) protocol_support.WriteError!{s} {{", .{element_name});
            writer.indent();
            try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
            try codegenWriteReturnCarrySelf(writer, next_init.withRequiredArrayRemaining());
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
        }
        try writer.println("pub fn finish(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
        writer.indent();
        try writer.println("if (self.remaining != 0) return error.MissingItems;", .{});
        try writer.println("const rest = self.rest;", .{});
        try codegenWriteNextReturn(writer, next_init);
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        if (!array.elementType.isNestedWriteScalar()) {
            const element_name = try std.fmt.allocPrint(writer.allocator, "{s}__element", .{type_name});
            defer writer.allocator.free(element_name);
            const array_next = try std.fmt.allocPrint(writer.allocator, "{s}", .{type_name});
            defer writer.allocator.free(array_next);
            try array.elementType.codegenNestedWriteType(writer, element_name, array_next, next_init.elementForArray());
        }
    }

    fn codegenArrayElementScalarMethod(self: *const ResolvedType, writer: *IndentedWriter, array_name: []const u8, next_init: WriteNextInit) anyerror!void {
        switch (self.*) {
            .native => |native| {
                if (native == .void) {
                    try writer.println("pub fn element(self: @This()) protocol_support.WriteError!{s} {{", .{array_name});
                } else {
                    try writer.println("pub fn element(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try native.codegenType(), array_name });
                }
                writer.indent();
                try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
                try writer.println("var rest = self.rest;", .{});
                try codegenNativeWrite(native, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                try writer.println("", .{});
            },
            .pstring => |pstring| {
                try writer.println("pub fn element(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{array_name});
                writer.indent();
                try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_pstring(rest, field_value, {s});", .{try pstring.countType.codegenType()});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                try writer.println("", .{});
            },
            .mapper => |mapper| {
                try writer.println("pub fn elementRaw(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try mapper.type.codegenType(), array_name });
                writer.indent();
                try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_{s}(rest, field_value);", .{@tagName(mapper.type)});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                try writer.println("", .{});
                for (mapper.mappings) |mapping| {
                    try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{s} {{", .{ idfmt(mapping.name), array_name });
                    writer.indent();
                    try writer.println("return self.elementRaw({});", .{mapping.value});
                    writer.unindent();
                    try writer.println("}}", .{});
                    try writer.println("", .{});
                }
            },
            .buffer => |buffer| {
                try writer.println("pub fn element(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{array_name});
                writer.indent();
                try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
                try writer.println("var rest = self.rest;", .{});
                switch (buffer) {
                    .constant => try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{}),
                    .type => |countType| try writer.println("rest = try protocol_support.write_buffer_counted(rest, field_value, {s});", .{try countType.codegenType()}),
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                try writer.println("", .{});
            },
            .bitfield => |bitfield| {
                try writer.println("pub fn element(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try codegenBitfieldValueType(writer.allocator, bitfield.fields), array_name });
                writer.indent();
                try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
                try writer.println("var rest = self.rest;", .{});
                try codegenBitfieldWrite(bitfield.fields, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                try writer.println("", .{});
            },
            .bitflags => |bitflags| {
                try writer.println("pub fn element(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try codegenBitflagsValueType(writer.allocator, bitflags.flags), array_name });
                writer.indent();
                try writer.println("if (self.remaining == 0) return error.TooManyItems;", .{});
                try writer.println("var rest = self.rest;", .{});
                try codegenBitflagsWrite(bitflags, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
                try writer.println("", .{});
            },
            else => unreachable,
        }
    }

    fn codegenOptionWriteType(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try codegenWriteStateFields(writer, next_init);
        try writer.println("", .{});
        try writer.println("pub fn none(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
        writer.indent();
        try writer.println("var rest = self.rest;", .{});
        try writer.println("rest = try protocol_support.write_bool(rest, false);", .{});
        try codegenWriteNextReturn(writer, next_init);
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
        if (self.isNestedWriteScalar()) {
            try self.codegenOptionSomeScalar(writer, next_name, next_init);
        } else {
            const value_name = try std.fmt.allocPrint(writer.allocator, "{s}__value", .{type_name});
            defer writer.allocator.free(value_name);
            try writer.println("pub fn some(self: @This()) protocol_support.WriteError!{s} {{", .{value_name});
            writer.indent();
            try writer.println("var rest = self.rest;", .{});
            try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
            try codegenWriteReturnCarryWithRest(writer, next_init, "rest");
            writer.unindent();
            try writer.println("}}", .{});
        }
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        if (!self.isNestedWriteScalar()) {
            const value_name = try std.fmt.allocPrint(writer.allocator, "{s}__value", .{type_name});
            defer writer.allocator.free(value_name);
            try self.codegenNestedWriteType(writer, value_name, next_name, next_init);
        }
    }

    fn codegenOptionSomeScalar(self: *const ResolvedType, writer: *IndentedWriter, next_name: []const u8, next_init: WriteNextInit) anyerror!void {
        switch (self.*) {
            .native => |native| {
                if (native == .void) {
                    try writer.println("pub fn some(self: @This()) protocol_support.WriteError!{s} {{", .{next_name});
                } else {
                    try writer.println("pub fn some(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try native.codegenType(), next_name });
                }
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try codegenNativeWrite(native, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .pstring => |pstring| {
                try writer.println("pub fn some(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{next_name});
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try writer.println("rest = try protocol_support.write_pstring(rest, field_value, {s});", .{try pstring.countType.codegenType()});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .mapper => {
                try writer.println("pub fn someRaw(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{next_name});
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{});
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .buffer => |buffer| {
                try writer.println("pub fn some(self: @This(), field_value: []const u8) protocol_support.WriteError!{s} {{", .{next_name});
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                switch (buffer) {
                    .constant => try writer.println("rest = try protocol_support.write_bytes(rest, field_value);", .{}),
                    .type => |countType| try writer.println("rest = try protocol_support.write_buffer_counted(rest, field_value, {s});", .{try countType.codegenType()}),
                }
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitfield => |bitfield| {
                try writer.println("pub fn some(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try codegenBitfieldValueType(writer.allocator, bitfield.fields), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try codegenBitfieldWrite(bitfield.fields, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            .bitflags => |bitflags| {
                try writer.println("pub fn some(self: @This(), field_value: {s}) protocol_support.WriteError!{s} {{", .{ try codegenBitflagsValueType(writer.allocator, bitflags.flags), next_name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_bool(rest, true);", .{});
                try codegenBitflagsWrite(bitflags, writer, "rest");
                try codegenWriteNextReturn(writer, next_init);
                writer.unindent();
                try writer.println("}}", .{});
            },
            else => unreachable,
        }
    }

    fn isNestedWriteScalar(self: *const ResolvedType) bool {
        return switch (self.*) {
            .native, .pstring, .mapper, .buffer, .bitfield, .bitflags => true,
            else => false,
        };
    }

    fn codegenReadViewType(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, depth: usize) anyerror!void {
        try writer.println("pub const {s} = struct {{", .{type_name});
        writer.indent();
        try writer.println("buffer: []const u8,", .{});
        try writer.println("", .{});

        if (depth < max_read_view_depth) {
            switch (self.*) {
                .container => |container| try self.codegenReadContainerView(writer, type_name, depth, container),
                .array => |array| try self.codegenReadArrayView(writer, type_name, depth, array),
                .option => |option| try option.codegenReadOptionView(writer, type_name, depth),
                .buffer => |buffer| try codegenReadBufferView(writer, buffer),
                .mapper => |mapper| try codegenReadMapperView(writer, mapper),
                else => {},
            }
        }

        try writer.println("pub fn payload(self: @This()) []const u8 {{", .{});
        writer.indent();
        try writer.println("return self.buffer;", .{});
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
        try writer.println("pub fn finish(self: @This()) protocol_support.ReadError!void {{", .{});
        writer.indent();
        try writer.println("var rest = self.buffer;", .{});
        try self.codegenSkip(writer, "rest");
        try writer.println("try (protocol_support.FinalCursor{{ .buffer = rest }}).finish();", .{});
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});

        if (depth < max_read_view_depth) {
            switch (self.*) {
                .container => |container| {
                    for (0.., container.fields) |i, field| {
                        if (field.type.isReadViewScalar()) continue;
                        const nested_name = try readViewTypeNameIndexed(writer.allocator, type_name, field.name, i);
                        defer writer.allocator.free(nested_name);
                        try field.type.codegenReadViewType(writer, nested_name, depth + 1);
                    }
                },
                .array => |array| {
                    if (!array.elementType.isReadViewScalar()) {
                        const element_name = try std.fmt.allocPrint(writer.allocator, "{s}__element", .{type_name});
                        defer writer.allocator.free(element_name);
                        try array.elementType.codegenReadViewType(writer, element_name, depth + 1);
                    }
                },
                .option => |option| {
                    if (!option.isReadViewScalar()) {
                        const value_name = try std.fmt.allocPrint(writer.allocator, "{s}__value", .{type_name});
                        defer writer.allocator.free(value_name);
                        try option.codegenReadViewType(writer, value_name, depth + 1);
                    }
                },
                else => {},
            }
        }
    }

    fn codegenReadContainerView(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, depth: usize, container: anytype) anyerror!void {
        _ = self;
        for (0.., container.fields) |i, field| {
            const return_type = try field.type.readViewReturnType(writer.allocator, type_name, field.name, i, depth);
            defer if (std.mem.startsWith(u8, return_type, "view")) writer.allocator.free(return_type);
            try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!{s} {{", .{ idfmt(field.name), return_type });
            writer.indent();
            try writer.println("var rest = self.buffer;", .{});
            try writer.println("rest = rest[0..];", .{});
            for (container.fields[0..i]) |previous| {
                try previous.type.codegenSkip(writer, "rest");
            }
            try field.type.codegenReadViewAccessorReturn(writer, "rest", type_name, field.name, i, depth);
            writer.unindent();
            try writer.println("}}", .{});
            try writer.println("", .{});
        }
    }

    fn codegenReadArrayView(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, depth: usize, array: anytype) anyerror!void {
        _ = self;
        const element_type = try array.elementType.readViewElementReturnType(writer.allocator, type_name, depth);
        defer if (std.mem.startsWith(u8, element_type, "view")) writer.allocator.free(element_type);

        try writer.println("pub const Iterator = struct {{", .{});
        writer.indent();
        try writer.println("rest: []const u8,", .{});
        try writer.println("remaining: usize,", .{});
        try writer.println("", .{});
        try writer.println("pub fn next(self: *@This()) protocol_support.ReadError!?{s} {{", .{element_type});
        writer.indent();
        try writer.println("if (self.remaining == 0) return null;", .{});
        try writer.println("self.remaining -= 1;", .{});
        if (array.elementType.isReadViewScalar()) {
            try array.elementType.codegenReadScalarAdvance(writer, "self.rest");
        } else {
            try writer.println("const start = self.rest;", .{});
            try array.elementType.codegenSkip(writer, "self.rest");
            try writer.println("return .{{ .buffer = protocol_support.slice_to_rest(start, self.rest) }};", .{});
        }
        writer.unindent();
        try writer.println("}}", .{});
        writer.unindent();
        try writer.println("}};", .{});
        try writer.println("", .{});
        try writer.println("pub fn iter(self: @This()) protocol_support.ReadError!Iterator {{", .{});
        writer.indent();
        try writer.println("var rest = self.buffer;", .{});
        const count_id = try codegenArrayCountRead(array.count, writer, "rest");
        try writer.println("return .{{ .rest = rest, .remaining = @intCast(count_{}) }};", .{count_id});
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
        try writer.println("pub fn len(self: @This()) protocol_support.ReadError!usize {{", .{});
        writer.indent();
        switch (array.count) {
            .constant => |constant| {
                try writer.println("_ = self;", .{});
                try writer.println("return {};", .{constant});
            },
            .type => |countType| {
                try writer.println("const count, _ = try protocol_support.read_{s}(self.buffer);", .{@tagName(countType)});
                try writer.println("return @intCast(count);", .{});
            },
            .field => {
                try writer.println("_ = self;", .{});
                try writer.println("return 0;", .{});
            },
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenReadBufferView(writer: *IndentedWriter, buffer: BufferCount) !void {
        try writer.println("pub fn bytes(self: @This()) protocol_support.ReadError![]const u8 {{", .{});
        writer.indent();
        switch (buffer) {
            .constant => |count| try writer.println("return (try protocol_support.read_buffer_exact(self.buffer, {}))[0];", .{count}),
            .type => |countType| try writer.println("return (try protocol_support.read_buffer_counted(self.buffer, {s}))[0];", .{try countType.codegenType()}),
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenReadMapperView(writer: *IndentedWriter, mapper: anytype) !void {
        try writer.println("pub fn value(self: @This()) protocol_support.ReadError!{s} {{", .{try mapper.type.codegenType()});
        writer.indent();
        try writer.println("return (try protocol_support.read_{s}(self.buffer))[0];", .{@tagName(mapper.type)});
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenReadOptionView(self: *const ResolvedType, writer: *IndentedWriter, type_name: []const u8, depth: usize) anyerror!void {
        const value_type = try self.readViewOptionValueReturnType(writer.allocator, type_name, depth);
        defer if (std.mem.startsWith(u8, value_type, "view")) writer.allocator.free(value_type);
        try writer.println("pub fn value(self: @This()) protocol_support.ReadError!?{s} {{", .{value_type});
        writer.indent();
        try writer.println("const present, var rest = try protocol_support.read_bool(self.buffer);", .{});
        try writer.println("if (!present) return null;", .{});
        if (self.isReadViewScalar()) {
            try self.codegenReadScalarAdvance(writer, "rest");
        } else {
            try writer.println("const start = rest;", .{});
            try self.codegenSkip(writer, "rest");
            try writer.println("return .{{ .buffer = protocol_support.slice_to_rest(start, rest) }};", .{});
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenReadViewAccessorReturn(self: *const ResolvedType, writer: *IndentedWriter, restName: []const u8, owner_name: []const u8, field_name: []const u8, index: usize, depth: usize) anyerror!void {
        switch (self.*) {
            .native, .pstring, .mapper, .buffer, .bitfield, .bitflags => try self.codegenReadScalarNoAdvance(writer, restName),
            else => {
                if (depth >= max_read_view_depth) {
                    try writer.println("const start = {s};", .{restName});
                    try self.codegenSkip(writer, restName);
                    try writer.println("return .{{ .buffer = protocol_support.slice_to_rest(start, {s}) }};", .{restName});
                } else {
                    const nested_name = try readViewTypeNameIndexed(writer.allocator, owner_name, field_name, index);
                    defer writer.allocator.free(nested_name);
                    try writer.println("const start = {s};", .{restName});
                    try self.codegenSkip(writer, restName);
                    try writer.println("return .{{ .buffer = protocol_support.slice_to_rest(start, {s}) }};", .{restName});
                }
            },
        }
    }

    fn codegenReadScalarNoAdvance(self: *const ResolvedType, writer: *IndentedWriter, restName: []const u8) anyerror!void {
        switch (self.*) {
            .native => |native| try codegenReadNativeReturn(native, writer, restName, false),
            .pstring => |pstring| {
                try writer.println("const read_value, _ = try protocol_support.read_pstring({s}, {s});", .{ restName, try pstring.countType.codegenType() });
                try writer.println("return read_value;", .{});
            },
            .mapper => |mapper| {
                try writer.println("const read_value, _ = try protocol_support.read_{s}({s});", .{ @tagName(mapper.type), restName });
                try writer.println("return read_value;", .{});
            },
            .buffer => |buffer| switch (buffer) {
                .constant => |count| {
                    try writer.println("const read_value, _ = try protocol_support.read_buffer_exact({s}, {});", .{ restName, count });
                    try writer.println("return read_value;", .{});
                },
                .type => |countType| {
                    try writer.println("const read_value, _ = try protocol_support.read_buffer_counted({s}, {s});", .{ restName, try countType.codegenType() });
                    try writer.println("return read_value;", .{});
                },
            },
            .bitfield => |bitfield| try codegenBitfieldReadReturn(bitfield.fields, writer, restName, false),
            .bitflags => |bitflags| try codegenBitflagsReadReturn(bitflags, writer, restName, false),
            else => unreachable,
        }
    }

    fn codegenReadScalarAdvance(self: *const ResolvedType, writer: *IndentedWriter, restName: []const u8) anyerror!void {
        switch (self.*) {
            .native => |native| try codegenReadNativeReturn(native, writer, restName, true),
            .pstring => |pstring| {
                try writer.println("const read_value, const after_value = try protocol_support.read_pstring({s}, {s});", .{ restName, try pstring.countType.codegenType() });
                try writer.println("{s} = after_value;", .{restName});
                try writer.println("return read_value;", .{});
            },
            .mapper => |mapper| {
                try writer.println("const read_value, const after_value = try protocol_support.read_{s}({s});", .{ @tagName(mapper.type), restName });
                try writer.println("{s} = after_value;", .{restName});
                try writer.println("return read_value;", .{});
            },
            .buffer => |buffer| switch (buffer) {
                .constant => |count| {
                    try writer.println("const read_value, const after_value = try protocol_support.read_buffer_exact({s}, {});", .{ restName, count });
                    try writer.println("{s} = after_value;", .{restName});
                    try writer.println("return read_value;", .{});
                },
                .type => |countType| {
                    try writer.println("const read_value, const after_value = try protocol_support.read_buffer_counted({s}, {s});", .{ restName, try countType.codegenType() });
                    try writer.println("{s} = after_value;", .{restName});
                    try writer.println("return read_value;", .{});
                },
            },
            .bitfield => |bitfield| try codegenBitfieldReadReturn(bitfield.fields, writer, restName, true),
            .bitflags => |bitflags| try codegenBitflagsReadReturn(bitflags, writer, restName, true),
            else => unreachable,
        }
    }

    fn isReadViewScalar(self: *const ResolvedType) bool {
        return switch (self.*) {
            .native, .pstring, .mapper, .buffer, .bitfield, .bitflags => true,
            else => false,
        };
    }

    fn readViewReturnType(self: *const ResolvedType, allocator: std.mem.Allocator, owner_name: []const u8, field_name: []const u8, index: usize, depth: usize) ![]const u8 {
        return switch (self.*) {
            .native => |native| try native.codegenType(),
            .pstring, .buffer => "[]const u8",
            .mapper => |mapper| try mapper.type.codegenType(),
            .bitfield => |bitfield| try codegenBitfieldValueType(allocator, bitfield.fields),
            .bitflags => |bitflags| try codegenBitflagsValueType(allocator, bitflags.flags),
            else => if (depth >= max_read_view_depth) "protocol_support.RawPayload" else try readViewTypeNameIndexed(allocator, owner_name, field_name, index),
        };
    }

    fn readViewElementReturnType(self: *const ResolvedType, allocator: std.mem.Allocator, owner_name: []const u8, depth: usize) ![]const u8 {
        return switch (self.*) {
            .native => |native| try native.codegenType(),
            .pstring, .buffer => "[]const u8",
            .mapper => |mapper| try mapper.type.codegenType(),
            .bitfield => |bitfield| try codegenBitfieldValueType(allocator, bitfield.fields),
            .bitflags => |bitflags| try codegenBitflagsValueType(allocator, bitflags.flags),
            else => if (depth >= max_read_view_depth) "protocol_support.RawPayload" else try std.fmt.allocPrint(allocator, "{s}__element", .{owner_name}),
        };
    }

    fn readViewOptionValueReturnType(self: *const ResolvedType, allocator: std.mem.Allocator, owner_name: []const u8, depth: usize) ![]const u8 {
        return switch (self.*) {
            .native => |native| try native.codegenType(),
            .pstring, .buffer => "[]const u8",
            .mapper => |mapper| try mapper.type.codegenType(),
            .bitfield => |bitfield| try codegenBitfieldValueType(allocator, bitfield.fields),
            .bitflags => |bitflags| try codegenBitflagsValueType(allocator, bitflags.flags),
            else => if (depth >= max_read_view_depth) "protocol_support.RawPayload" else try std.fmt.allocPrint(allocator, "{s}__value", .{owner_name}),
        };
    }

    pub fn codegenViewAccessors(self: *const ResolvedType, writer: *IndentedWriter) anyerror!void {
        switch (self.*) {
            .container => |container| {
                for (0.., container.fields) |i, field| {
                    try field.type.codegenViewAccessor(writer, field.name, container.fields[0..i]);
                }
            },
            else => {},
        }
    }

    fn codegenViewAccessor(self: *const ResolvedType, writer: *IndentedWriter, field_name: []const u8, previous: []ResolvedField) anyerror!void {
        try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!{s} {{", .{ idfmt(field_name), try self.codegenViewReturnType() });
        writer.indent();
        try writer.println("var rest = self.buffer;", .{});
        for (previous) |field| {
            try field.type.codegenSkip(writer, "rest");
        }
        switch (self.*) {
            .native => |native| {
                if (native == .void) {
                    try writer.println("return {{}};", .{});
                } else {
                    try writer.println("const value, _ = try protocol_support.read_{s}(rest);", .{@tagName(native)});
                    try writer.println("return value;", .{});
                }
            },
            .pstring => |pstring| {
                try writer.println("const value, _ = try protocol_support.read_pstring(rest, {s});", .{try pstring.countType.codegenType()});
                try writer.println("return value;", .{});
            },
            else => {
                try writer.println("const start = rest;", .{});
                try self.codegenSkip(writer, "rest");
                try writer.println("return .{{ .buffer = protocol_support.slice_to_rest(start, rest) }};", .{});
            },
        }
        writer.unindent();
        try writer.println("}}", .{});
        try writer.println("", .{});
    }

    fn codegenViewReturnType(self: *const ResolvedType) ![]const u8 {
        return switch (self.*) {
            .native => |native| try native.codegenType(),
            .pstring => "[]const u8",
            else => "protocol_support.RawPayload",
        };
    }
};

fn bitfieldBits(fields: []BitfieldField) usize {
    var bits: usize = 0;
    for (fields) |field| bits += field.type.size;
    return bits;
}

fn bitfieldFieldType(field: BitfieldField) []const u8 {
    if (field.type.signed) {
        if (field.type.size <= 8) return "i8";
        if (field.type.size <= 16) return "i16";
        if (field.type.size <= 32) return "i32";
        return "i64";
    }
    if (field.type.size == 1) return "bool";
    if (field.type.size <= 8) return "u8";
    if (field.type.size <= 16) return "u16";
    if (field.type.size <= 32) return "u32";
    return "u64";
}

fn codegenBitfieldValueType(allocator: std.mem.Allocator, fields: []BitfieldField) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "struct { ");
    for (fields) |field| {
        const field_name = try std.fmt.allocPrint(allocator, "{f}", .{idfmt(field.name)});
        defer allocator.free(field_name);
        try result.appendSlice(allocator, field_name);
        try result.appendSlice(allocator, ": ");
        try result.appendSlice(allocator, bitfieldFieldType(field));
        try result.appendSlice(allocator, ", ");
    }
    try result.appendSlice(allocator, "}");
    return result.toOwnedSlice(allocator);
}

fn codegenBitflagsValueType(allocator: std.mem.Allocator, flags: []const []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "struct { ");
    for (flags) |flag| {
        const field_name = try std.fmt.allocPrint(allocator, "{f}", .{idfmt(flag)});
        defer allocator.free(field_name);
        try result.appendSlice(allocator, field_name);
        try result.appendSlice(allocator, ": bool = false, ");
    }
    try result.appendSlice(allocator, "}");
    return result.toOwnedSlice(allocator);
}

fn codegenBitfieldReadReturn(fields: []BitfieldField, writer: *IndentedWriter, restName: []const u8, comptime advance: bool) !void {
    const total_bits = bitfieldBits(fields);
    const id = writer.nextId();
    if (advance) {
        try writer.println("const packed_{}, const after_packed_{} = try protocol_support.read_packed_bits({s}, {});", .{ id, id, restName, total_bits });
        try writer.println("{s} = after_packed_{};", .{ restName, id });
    } else {
        try writer.println("const packed_{}, _ = try protocol_support.read_packed_bits({s}, {});", .{ id, restName, total_bits });
    }
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("return ", .{});
    try codegenBitfieldValueLiteral(fields, writer, try std.fmt.allocPrint(writer.allocator, "packed_{}", .{id}));
    try writer.writer.print(";\n", .{});
}

fn codegenBitfieldValueLiteral(fields: []BitfieldField, writer: *IndentedWriter, packed_name: []const u8) !void {
    defer writer.allocator.free(packed_name);
    const total_bits = bitfieldBits(fields);
    try writer.writer.print(".{{\n", .{});
    writer.indent();
    var shift: usize = total_bits;
    for (fields) |field| {
        shift -= field.type.size;
        const field_type = bitfieldFieldType(field);
        if (field.type.signed) {
            try writer.println(".{f} = @as({s}, @intCast(protocol_support.unpack_signed({s}, {}, {}))),", .{ idfmt(field.name), field_type, packed_name, shift, field.type.size });
        } else if (field.type.size == 1) {
            try writer.println(".{f} = protocol_support.unpack_unsigned({s}, {}, {}) != 0,", .{ idfmt(field.name), packed_name, shift, field.type.size });
        } else {
            try writer.println(".{f} = @as({s}, @intCast(protocol_support.unpack_unsigned({s}, {}, {}))),", .{ idfmt(field.name), field_type, packed_name, shift, field.type.size });
        }
    }
    writer.unindent();
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("}}", .{});
}

fn bitfieldFieldByName(fields: []BitfieldField, name: []const u8) ?BitfieldField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

fn bitflagIndex(flags: []const []const u8, name: []const u8) ?usize {
    for (0.., flags) |i, flag| {
        if (std.mem.eql(u8, flag, name)) return i;
    }
    return null;
}

fn codegenBitfieldMemberValue(fields: []BitfieldField, writer: *IndentedWriter, packed_name: []const u8, member: []const u8) !void {
    defer writer.allocator.free(packed_name);
    const total_bits = bitfieldBits(fields);
    var shift: usize = total_bits;
    for (fields) |field| {
        shift -= field.type.size;
        if (!std.mem.eql(u8, field.name, member)) continue;
        const field_type = bitfieldFieldType(field);
        if (field.type.signed) {
            try writer.writer.print("@as({s}, @intCast(protocol_support.unpack_signed({s}, {}, {})))", .{ field_type, packed_name, shift, field.type.size });
        } else if (field.type.size == 1) {
            try writer.writer.print("(protocol_support.unpack_unsigned({s}, {}, {}) != 0)", .{ packed_name, shift, field.type.size });
        } else {
            try writer.writer.print("@as({s}, @intCast(protocol_support.unpack_unsigned({s}, {}, {})))", .{ field_type, packed_name, shift, field.type.size });
        }
        return;
    }
    try writer.writer.print("0", .{});
}

fn codegenBitfieldWrite(fields: []BitfieldField, writer: *IndentedWriter, restName: []const u8) !void {
    const total_bits = bitfieldBits(fields);
    try writer.println("var packed_bits: u64 = 0;", .{});
    var shift: usize = total_bits;
    for (fields) |field| {
        shift -= field.type.size;
        if (field.type.signed) {
            try writer.println("packed_bits |= protocol_support.pack_signed(field_value.{f}, {}) << {};", .{ idfmt(field.name), field.type.size, shift });
        } else if (field.type.size == 1) {
            try writer.println("packed_bits |= @as(u64, if (field_value.{f}) 1 else 0) << {};", .{ idfmt(field.name), shift });
        } else {
            try writer.println("packed_bits |= protocol_support.pack_unsigned(field_value.{f}, {}) << {};", .{ idfmt(field.name), field.type.size, shift });
        }
    }
    try writer.println("{s} = try protocol_support.write_packed_bits({s}, {}, packed_bits);", .{ restName, restName, total_bits });
}

fn codegenBitflagsReadReturn(bitflags: anytype, writer: *IndentedWriter, restName: []const u8, comptime advance: bool) !void {
    const id = writer.nextId();
    if (advance) {
        try writer.println("const flags_{}, const after_flags_{} = try protocol_support.read_{s}({s});", .{ id, id, @tagName(bitflags.type), restName });
        try writer.println("{s} = after_flags_{};", .{ restName, id });
    } else {
        try writer.println("const flags_{}, _ = try protocol_support.read_{s}({s});", .{ id, @tagName(bitflags.type), restName });
    }
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("return ", .{});
    try codegenBitflagsValueLiteral(bitflags, writer, try std.fmt.allocPrint(writer.allocator, "flags_{}", .{id}));
    try writer.writer.print(";\n", .{});
}

fn codegenBitflagsValueLiteral(bitflags: anytype, writer: *IndentedWriter, flags_name: []const u8) !void {
    defer writer.allocator.free(flags_name);
    try writer.writer.print(".{{\n", .{});
    writer.indent();
    for (0.., bitflags.flags) |i, flag| {
        try writer.println(".{f} = ({s} & @as({s}, {})) != 0,", .{ idfmt(flag), flags_name, try bitflags.type.codegenType(), @as(u64, 1) << @intCast(i) });
    }
    writer.unindent();
    try printIndent(writer.writer, writer.level);
    try writer.writer.print("}}", .{});
}

fn codegenBitflagsWrite(bitflags: anytype, writer: *IndentedWriter, restName: []const u8) !void {
    try writer.println("var flags_bits: {s} = 0;", .{try bitflags.type.codegenType()});
    for (0.., bitflags.flags) |i, flag| {
        try writer.println("if (field_value.{f}) flags_bits |= @as({s}, {});", .{ idfmt(flag), try bitflags.type.codegenType(), @as(u64, 1) << @intCast(i) });
    }
    try writer.println("{s} = try protocol_support.write_{s}({s}, flags_bits);", .{ restName, @tagName(bitflags.type), restName });
}

const max_ast_view_depth = 4;
const max_ast_write_depth = 4;
const max_read_view_depth = 4;

fn astViewTypeName(allocator: std.mem.Allocator, owner_name: []const u8, field_name: []const u8, depth: usize) ![]const u8 {
    _ = depth;
    const sanitized = try sanitizeTypeNamePart(allocator, field_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "view__{s}__{s}", .{ owner_name, sanitized });
}

fn readViewTypeName(allocator: std.mem.Allocator, owner_name: []const u8, field_name: []const u8) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, field_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "view__{s}__{s}", .{ owner_name, sanitized });
}

fn namedViewTypeName(allocator: std.mem.Allocator, type_name: []const u8) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, type_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "view_type__{s}", .{sanitized});
}

fn readViewTypeNameIndexed(allocator: std.mem.Allocator, owner_name: []const u8, field_name: []const u8, index: usize) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, field_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "view__{s}__{}__{s}", .{ owner_name, index, sanitized });
}

fn codegenAstWriteNamedReferenceType(writer: *IndentedWriter, reference: []const u8, type_name: []const u8, next_name: []const u8, next_init: WriteNextInit) !void {
    const function_name = try namedWriteFunctionName(writer.allocator, reference);
    defer writer.allocator.free(function_name);
    const cont_name = try std.fmt.allocPrint(writer.allocator, "{s}__continuation", .{type_name});
    defer writer.allocator.free(cont_name);
    try codegenWriteContinuationType(writer, cont_name, next_name, next_init);
    try writer.println("pub const {s} = {s}({s});", .{ type_name, function_name, cont_name });
    try writer.println("", .{});
}

fn codegenWriteContinuationType(writer: *IndentedWriter, cont_name: []const u8, next_name: []const u8, next_init: WriteNextInit) !void {
    try writer.println("pub const {s} = struct {{", .{cont_name});
    writer.indent();
    try writer.println("pub const Next = {s};", .{next_name});
    if (next_init.carriesArrayRemaining()) try writer.println("remaining: usize,", .{});
    if (next_init.carriesParentRemaining()) try writer.println("parent_remaining: usize,", .{});
    if (next_init.carriesContinuation()) try writer.println("cont: Cont,", .{});
    try writer.println("", .{});
    try writer.println("pub fn init(cursor: anytype) @This() {{", .{});
    writer.indent();
    if (next_init.carriesArrayRemaining() or next_init.carriesParentRemaining() or next_init.carriesContinuation()) {
        try writer.println("return .{{", .{});
        writer.indent();
        if (next_init.carriesArrayRemaining()) try writer.println(".remaining = cursor.remaining,", .{});
        if (next_init.carriesParentRemaining()) try writer.println(".parent_remaining = cursor.parent_remaining,", .{});
        if (next_init.carriesContinuation()) try writer.println(".cont = cursor.cont,", .{});
        writer.unindent();
        try writer.println("}};", .{});
    } else {
        try writer.println("_ = cursor;", .{});
        try writer.println("return .{{}};", .{});
    }
    writer.unindent();
    try writer.println("}}", .{});
    try writer.println("", .{});
    try writer.println("pub fn complete(self: @This(), buffer: []u8, rest: []u8) protocol_support.WriteError!Next {{", .{});
    writer.indent();
    try codegenWriteContinuationComplete(writer, next_init);
    writer.unindent();
    try writer.println("}}", .{});
    writer.unindent();
    try writer.println("}};", .{});
    try writer.println("", .{});
}

fn codegenWriteContinuationComplete(writer: *IndentedWriter, init: WriteNextInit) !void {
    switch (init) {
        .normal => {
            try writer.println("_ = self;", .{});
            try writer.println("return .{{ .buffer = buffer, .rest = rest }};", .{});
        },
        .array_preserve => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining }};", .{}),
        .array_element => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining - 1 }};", .{}),
        .array_preserve_parent => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining, .parent_remaining = self.parent_remaining }};", .{}),
        .array_element_parent => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining - 1, .parent_remaining = self.parent_remaining }};", .{}),
        .restore_parent_preserve => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.parent_remaining }};", .{}),
        .restore_parent_element => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.parent_remaining - 1 }};", .{}),
        .preserve_cont => try writer.println("return .{{ .buffer = buffer, .rest = rest, .cont = self.cont }};", .{}),
        .normal_cont => try writer.println("return self.cont.complete(buffer, rest);", .{}),
        .array_preserve_cont => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining, .cont = self.cont }};", .{}),
        .array_element_cont => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining - 1, .cont = self.cont }};", .{}),
        .array_preserve_parent_cont => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining, .parent_remaining = self.parent_remaining, .cont = self.cont }};", .{}),
        .array_element_parent_cont => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.remaining - 1, .parent_remaining = self.parent_remaining, .cont = self.cont }};", .{}),
        .restore_parent_preserve_cont => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.parent_remaining, .cont = self.cont }};", .{}),
        .restore_parent_element_cont => try writer.println("return .{{ .buffer = buffer, .rest = rest, .remaining = self.parent_remaining - 1, .cont = self.cont }};", .{}),
    }
}

fn sanitizeTypeNamePart(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer result.deinit(allocator);
    for (input) |c| {
        try result.append(allocator, if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
    }
    return result.toOwnedSlice(allocator);
}

fn codegenReadNativeReturn(native: NativeType, writer: *IndentedWriter, restName: []const u8, comptime advance: bool) !void {
    if (native == .void) {
        try writer.println("return {{}};", .{});
        return;
    }
    if (advance) {
        try writer.println("const read_value, const after_value = try protocol_support.read_{s}({s});", .{ @tagName(native), restName });
        try writer.println("{s} = after_value;", .{restName});
    } else {
        try writer.println("const read_value, _ = try protocol_support.read_{s}({s});", .{ @tagName(native), restName });
    }
    try writer.println("return read_value;", .{});
}

fn codegenNativeSkip(native: NativeType, writer: *IndentedWriter, restName: []const u8) !void {
    switch (native) {
        .void => {},
        .nbt => try writer.println("{s} = try protocol_support.skip_nbt({s});", .{ restName, restName }),
        .anonymousNbt => try writer.println("{s} = try protocol_support.skip_anonymous_nbt({s});", .{ restName, restName }),
        .optionalNbt => try writer.println("{s} = try protocol_support.skip_optional_nbt({s});", .{ restName, restName }),
        .anonOptionalNbt => try writer.println("{s} = try protocol_support.skip_anon_optional_nbt({s});", .{ restName, restName }),
        .restBuffer => try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName }),
        else => try writer.println("{s} = (try protocol_support.read_{s}({s}))[1];", .{ restName, @tagName(native), restName }),
    }
}

fn codegenArrayCountRead(count: ArrayCount, writer: *IndentedWriter, restName: []const u8) !usize {
    const id = writer.nextId();
    switch (count) {
        .constant => |constant| try writer.println("const count_{}: usize = {};", .{ id, constant }),
        .type => |countType| {
            try writer.println("const count_{}, const rest_{} = try protocol_support.read_{s}({s});", .{ id, id, @tagName(countType), restName });
            try writer.println("{s} = rest_{};", .{ restName, id });
        },
        .field => {
            try writer.println("const count_{}: usize = 0;", .{id});
            try writer.println("{s} = try protocol_support.skip_rest({s});", .{ restName, restName });
        },
    }
    return id;
}

const CursorTreeTails = union(enum) {
    one: *Cursor,
    many: std.ArrayList(*Cursor),
};

const CursorTree = struct {
    head: *Cursor,
    tails: CursorTreeTails,

    pub fn updateNext(self: *CursorTree, next: *Cursor) !void {
        switch (self.tails) {
            .many => |many| {
                for (many.items) |f| {
                    try f.updateNext(next);
                }
            },
            .one => |o| {
                try o.updateNext(next);
                self.tails = .{ .one = o };
            },
        }
    }
};

const CompareBinding = struct {
    name: []const u8,
    type: *const Type,
    value_name: []const u8,
};

const CursorVariant = struct {
    name: []const u8,
    value: i64,
    cursor: *Cursor,
};

const Cursor = struct {
    name: []const u8,
    kind: union(enum) {
        simple: struct {
            readType: union(enum) {
                native: NativeType,
                pstring: NativeType,
                bitfield: []BitfieldField,
                bitflags: struct { type: NativeType, flags: []const []const u8 },

                pub fn codegenType(self: @This()) ![]const u8 {
                    return switch (self) {
                        .native => |native| try native.codegenType(),
                        .pstring => "[]const u8",
                        .bitfield => |fields| try codegenBitfieldValueType(std.heap.page_allocator, fields),
                        .bitflags => |bitflags| try codegenBitflagsValueType(std.heap.page_allocator, bitflags.flags),
                    };
                }
            },
            next: ?*Cursor,
        },
        complex: struct {
            type: *const ResolvedType,
            next: ?*Cursor,
        },
        variants: struct {
            readType: NativeType,
            variants: []CursorVariant,
            default: *Cursor,
        },
        todo,
    },
    fieldName: []const u8,
    visited: bool = false,
    write_visited: bool = false,

    pub fn codegen(self: *Cursor, writer: *IndentedWriter) !void {
        if (self.visited) {
            return;
        }
        self.visited = true;

        try writer.println("pub const {s} = struct {{", .{self.name});
        writer.indent();
        try writer.println("buffer: []const u8,", .{});
        try writer.println("", .{});

        switch (self.kind) {
            .simple => |simple| {
                const value_type = switch (simple.readType) {
                    .bitfield => |fields| blk: {
                        try writer.println("pub const Value = {s};", .{try codegenBitfieldValueType(writer.allocator, fields)});
                        try writer.println("", .{});
                        break :blk "Value";
                    },
                    .bitflags => |bitflags| blk: {
                        try writer.println("pub const Value = {s};", .{try codegenBitflagsValueType(writer.allocator, bitflags.flags)});
                        try writer.println("", .{});
                        break :blk "Value";
                    },
                    else => try simple.readType.codegenType(),
                };
                try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!struct {{ {s}, {s} }} {{", .{ idfmt(self.fieldName), value_type, cursorName(simple.next) });
                writer.indent();
                switch (simple.readType) {
                    .native => |native| {
                        try writer.println("const value, const rest = try protocol_support.read_{s}(self.buffer);", .{@tagName(native)});
                        try writer.println("return .{{ value, .{{ .buffer = rest }} }};", .{});
                    },
                    .pstring => |pstring| {
                        try writer.println("const length, const rest = try protocol_support.read_{s}(self.buffer);", .{@tagName(pstring)});
                        try writer.println("const size: usize = @intCast(length);", .{});
                        try writer.println("return .{{ rest[0..size], .{{.buffer = rest[size..] }} }};", .{});
                    },
                    .bitfield => |fields| {
                        const id = writer.nextId();
                        try writer.println("const packed_{}, const rest = try protocol_support.read_packed_bits(self.buffer, {});", .{ id, bitfieldBits(fields) });
                        try printIndent(writer.writer, writer.level);
                        try writer.writer.print("const value: Value = ", .{});
                        try codegenBitfieldValueLiteral(fields, writer, try std.fmt.allocPrint(writer.allocator, "packed_{}", .{id}));
                        try writer.writer.print(";\n", .{});
                        try writer.println("return .{{ value, .{{ .buffer = rest }} }};", .{});
                    },
                    .bitflags => |bitflags| {
                        const id = writer.nextId();
                        try writer.println("const flags_{}, const rest = try protocol_support.read_{s}(self.buffer);", .{ id, @tagName(bitflags.type) });
                        try printIndent(writer.writer, writer.level);
                        try writer.writer.print("const value: Value = ", .{});
                        try codegenBitflagsValueLiteral(bitflags, writer, try std.fmt.allocPrint(writer.allocator, "flags_{}", .{id}));
                        try writer.writer.print(";\n", .{});
                        try writer.println("return .{{ value, .{{ .buffer = rest }} }};", .{});
                    },
                }
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}};", .{});
                try writer.println("", .{});
                if (simple.next) |next| {
                    try next.codegen(writer);
                }
            },
            .complex => |complex| {
                const view_name = try readViewTypeName(writer.allocator, self.name, self.fieldName);
                defer writer.allocator.free(view_name);
                try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!struct {{ {s}, {s} }} {{", .{ idfmt(self.fieldName), view_name, cursorName(complex.next) });
                writer.indent();
                try writer.println("var rest = self.buffer;", .{});
                try complex.type.codegenSkip(writer, "rest");
                try writer.println("return .{{ .{{ .buffer = protocol_support.slice_to_rest(self.buffer, rest) }}, .{{ .buffer = rest }} }};", .{});
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}};", .{});
                try writer.println("", .{});
                try complex.type.codegenReadViewType(writer, view_name, 0);
                if (complex.next) |next| {
                    try next.codegen(writer);
                }
            },
            .variants => |variants| {
                try writer.println("pub fn {f}(self: @This()) protocol_support.ReadError!union(enum) {{", .{idfmt(self.fieldName)});
                writer.indent();
                for (variants.variants) |variant| {
                    try writer.println("{s}: {s},", .{ variant.name, variant.cursor.name });
                }
                try writer.println("default: {s},", .{variants.default.name});
                writer.unindent();
                try writer.println("}} {{", .{});
                writer.indent();
                try writer.println("const value, const rest = try protocol_support.read_{s}(self.buffer);", .{@tagName(variants.readType)});
                try writer.println("return switch (value) {{", .{});
                writer.indent();
                for (variants.variants) |variant| {
                    try writer.println("{} => .{{ .{s} = .{{ .buffer = rest }} }},", .{ variant.value, variant.name });
                }
                try writer.println("else => .{{ .default = .{{ .buffer = rest }} }},", .{});
                writer.unindent();
                try writer.println("}};", .{});
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}};", .{});
                try writer.println("", .{});
                for (variants.variants) |variant| {
                    try variant.cursor.codegen(writer);
                }
                try variants.default.codegen(writer);
            },
            .todo => unreachable,
        }
    }

    pub fn codegenWrite(self: *Cursor, writer: *IndentedWriter) !void {
        if (self.write_visited) {
            return;
        }
        self.write_visited = true;

        try writer.println("pub const write__{s} = struct {{", .{self.name});
        writer.indent();
        try writer.println("buffer: []u8,", .{});
        try writer.println("rest: []u8,", .{});
        try writer.println("", .{});

        switch (self.kind) {
            .simple => |simple| {
                switch (simple.readType) {
                    .bitfield => |fields| {
                        try writer.println("pub const Value = {s};", .{try codegenBitfieldValueType(writer.allocator, fields)});
                        try writer.println("", .{});
                    },
                    .bitflags => |bitflags| {
                        try writer.println("pub const Value = {s};", .{try codegenBitflagsValueType(writer.allocator, bitflags.flags)});
                        try writer.println("", .{});
                    },
                    else => {},
                }
                try writeSimpleCursorMethodSignature(writer, self.fieldName, simple.readType, writeCursorName(simple.next));
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                switch (simple.readType) {
                    .native => |native| try codegenNativeWrite(native, writer, "rest"),
                    .pstring => |pstring| try writer.println("rest = try protocol_support.write_pstring(rest, field_value, {s});", .{try pstring.codegenType()}),
                    .bitfield => |fields| try codegenBitfieldWrite(fields, writer, "rest"),
                    .bitflags => |bitflags| try codegenBitflagsWrite(bitflags, writer, "rest"),
                }
                try writer.println("return .{{ .buffer = self.buffer, .rest = rest }};", .{});
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}};", .{});
                try writer.println("", .{});
                if (simple.next) |next| {
                    try next.codegenWrite(writer);
                }
            },
            .complex => |complex| {
                const nested_name = try nestedWriteTypeName(writer.allocator, self.name, self.fieldName);
                defer writer.allocator.free(nested_name);
                const next_name = try writeCursorNameAlloc(writer.allocator, complex.next);
                defer writer.allocator.free(next_name);

                try complex.type.codegenNestedWriteEntry(writer, self.fieldName, nested_name, next_name, .normal);
                writer.unindent();
                try writer.println("}};", .{});
                try writer.println("", .{});
                try complex.type.codegenNestedWriteType(writer, nested_name, next_name, .normal);
                if (complex.next) |next| {
                    try next.codegenWrite(writer);
                }
            },
            .variants => |variants| {
                for (variants.variants) |variant| {
                    try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!write__{s} {{", .{ idfmt(variant.name), variant.cursor.name });
                    writer.indent();
                    try writer.println("var rest = self.rest;", .{});
                    try writer.println("rest = try protocol_support.write_{s}(rest, {});", .{ @tagName(variants.readType), variant.value });
                    try writer.println("return .{{ .buffer = self.buffer, .rest = rest }};", .{});
                    writer.unindent();
                    try writer.println("}}", .{});
                    try writer.println("", .{});
                }
                try writer.println("pub fn default(self: @This(), field_value: {s}) protocol_support.WriteError!write__{s} {{", .{ try variants.readType.codegenType(), variants.default.name });
                writer.indent();
                try writer.println("var rest = self.rest;", .{});
                try writer.println("rest = try protocol_support.write_{s}(rest, field_value);", .{@tagName(variants.readType)});
                try writer.println("return .{{ .buffer = self.buffer, .rest = rest }};", .{});
                writer.unindent();
                try writer.println("}}", .{});
                writer.unindent();
                try writer.println("}};", .{});
                try writer.println("", .{});
                for (variants.variants) |variant| {
                    try variant.cursor.codegenWrite(writer);
                }
                try variants.default.codegenWrite(writer);
            },
            .todo => unreachable,
        }
    }

    pub fn updateNext(self: *Cursor, next: *Cursor) !void {
        switch (self.kind) {
            .simple => {
                self.kind.simple.next = next;
            },
            .complex => {
                self.kind.complex.next = next;
            },
            .todo => {},
            else => return error.UpdateNextOnNonSimple,
        }
    }
};

fn cursorName(cursor: ?*Cursor) []const u8 {
    return if (cursor) |c| c.name else "protocol_support.FinalCursor";
}

const WriteNextInit = enum {
    normal,
    array_preserve,
    array_element,
    array_preserve_parent,
    array_element_parent,
    restore_parent_preserve,
    restore_parent_element,
    preserve_cont,
    normal_cont,
    array_preserve_cont,
    array_element_cont,
    array_preserve_parent_cont,
    array_element_parent_cont,
    restore_parent_preserve_cont,
    restore_parent_element_cont,

    fn carriesArrayRemaining(self: WriteNextInit) bool {
        return switch (self) {
            .normal => false,
            .preserve_cont => false,
            .normal_cont => false,
            .array_preserve,
            .array_element,
            .array_preserve_parent,
            .array_element_parent,
            .restore_parent_preserve,
            .restore_parent_element,
            .array_preserve_cont,
            .array_element_cont,
            .array_preserve_parent_cont,
            .array_element_parent_cont,
            .restore_parent_preserve_cont,
            .restore_parent_element_cont,
            => true,
        };
    }

    fn carriesParentRemaining(self: WriteNextInit) bool {
        return switch (self) {
            .array_preserve_parent,
            .array_element_parent,
            .restore_parent_preserve,
            .restore_parent_element,
            .array_preserve_parent_cont,
            .array_element_parent_cont,
            .restore_parent_preserve_cont,
            .restore_parent_element_cont,
            => true,
            .normal,
            .array_preserve,
            .array_element,
            .preserve_cont,
            .normal_cont,
            .array_preserve_cont,
            .array_element_cont,
            => false,
        };
    }

    fn carriesContinuation(self: WriteNextInit) bool {
        return switch (self) {
            .normal_cont,
            .preserve_cont,
            .array_preserve_cont,
            .array_element_cont,
            .array_preserve_parent_cont,
            .array_element_parent_cont,
            .restore_parent_preserve_cont,
            .restore_parent_element_cont,
            => true,
            else => false,
        };
    }

    fn preserveForSibling(self: WriteNextInit) WriteNextInit {
        return if (self.carriesParentRemaining() and self.carriesContinuation())
            .array_preserve_parent_cont
        else if (self.carriesParentRemaining())
            .array_preserve_parent
        else if (self.carriesArrayRemaining() and self.carriesContinuation())
            .array_preserve_cont
        else if (self.carriesArrayRemaining())
            .array_preserve
        else if (self.carriesContinuation())
            .preserve_cont
        else
            .normal;
    }

    fn withRequiredArrayRemaining(self: WriteNextInit) WriteNextInit {
        return if (self.carriesArrayRemaining()) self else if (self.carriesContinuation()) .array_preserve_cont else .array_preserve;
    }

    fn elementForArray(self: WriteNextInit) WriteNextInit {
        return if (self.carriesParentRemaining() and self.carriesContinuation())
            .array_element_parent_cont
        else if (self.carriesParentRemaining())
            .array_element_parent
        else if (self.carriesContinuation())
            .array_element_cont
        else
            .array_element;
    }

    fn arrayFieldInit(self: WriteNextInit) WriteNextInit {
        return switch (self) {
            .array_preserve => .restore_parent_preserve,
            .array_element => .restore_parent_element,
            .array_preserve_parent => .restore_parent_preserve,
            .array_element_parent => .restore_parent_element,
            .array_preserve_cont => .restore_parent_preserve_cont,
            .array_element_cont => .restore_parent_element_cont,
            .array_preserve_parent_cont => .restore_parent_preserve_cont,
            .array_element_parent_cont => .restore_parent_element_cont,
            else => self,
        };
    }
};

fn codegenWriteNextReturn(writer: *IndentedWriter, init: WriteNextInit) !void {
    switch (init) {
        .normal => try writer.println("return .{{ .buffer = self.buffer, .rest = rest }};", .{}),
        .array_preserve => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining }};", .{}),
        .array_element => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining - 1 }};", .{}),
        .array_preserve_parent => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining, .parent_remaining = self.parent_remaining }};", .{}),
        .array_element_parent => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining - 1, .parent_remaining = self.parent_remaining }};", .{}),
        .restore_parent_preserve => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.parent_remaining }};", .{}),
        .restore_parent_element => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.parent_remaining - 1 }};", .{}),
        .preserve_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .cont = self.cont }};", .{}),
        .normal_cont => try writer.println("return self.cont.complete(self.buffer, rest);", .{}),
        .array_preserve_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining, .cont = self.cont }};", .{}),
        .array_element_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining - 1, .cont = self.cont }};", .{}),
        .array_preserve_parent_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining, .parent_remaining = self.parent_remaining, .cont = self.cont }};", .{}),
        .array_element_parent_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.remaining - 1, .parent_remaining = self.parent_remaining, .cont = self.cont }};", .{}),
        .restore_parent_preserve_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.parent_remaining, .cont = self.cont }};", .{}),
        .restore_parent_element_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = rest, .remaining = self.parent_remaining - 1, .cont = self.cont }};", .{}),
    }
}

fn codegenWriteStateFields(writer: *IndentedWriter, init: WriteNextInit) !void {
    try writer.println("buffer: []u8,", .{});
    try writer.println("rest: []u8,", .{});
    if (init.carriesArrayRemaining()) try writer.println("remaining: usize,", .{});
    if (init.carriesParentRemaining()) try writer.println("parent_remaining: usize,", .{});
    if (init.carriesContinuation()) try writer.println("cont: Cont,", .{});
}

fn codegenWriteReturnWithRest(writer: *IndentedWriter, init: WriteNextInit, rest_name: []const u8) !void {
    switch (init) {
        .normal => try writer.println("return .{{ .buffer = self.buffer, .rest = {s} }};", .{rest_name}),
        .array_preserve => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining }};", .{rest_name}),
        .array_element => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining - 1 }};", .{rest_name}),
        .array_preserve_parent => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining, .parent_remaining = self.parent_remaining }};", .{rest_name}),
        .array_element_parent => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining - 1, .parent_remaining = self.parent_remaining }};", .{rest_name}),
        .restore_parent_preserve => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.parent_remaining }};", .{rest_name}),
        .restore_parent_element => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.parent_remaining - 1 }};", .{rest_name}),
        .preserve_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .cont = self.cont }};", .{rest_name}),
        .normal_cont => try writer.println("return self.cont.complete(self.buffer, {s});", .{rest_name}),
        .array_preserve_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining, .cont = self.cont }};", .{rest_name}),
        .array_element_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining - 1, .cont = self.cont }};", .{rest_name}),
        .array_preserve_parent_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining, .parent_remaining = self.parent_remaining, .cont = self.cont }};", .{rest_name}),
        .array_element_parent_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining - 1, .parent_remaining = self.parent_remaining, .cont = self.cont }};", .{rest_name}),
        .restore_parent_preserve_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.parent_remaining, .cont = self.cont }};", .{rest_name}),
        .restore_parent_element_cont => try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.parent_remaining - 1, .cont = self.cont }};", .{rest_name}),
    }
}

fn codegenWriteReturnSelf(writer: *IndentedWriter, init: WriteNextInit) !void {
    try codegenWriteReturnWithRest(writer, init, "self.rest");
}

fn codegenWriteReturnCarryWithRest(writer: *IndentedWriter, init: WriteNextInit, rest_name: []const u8) !void {
    if (init.carriesParentRemaining() and init.carriesContinuation()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining, .parent_remaining = self.parent_remaining, .cont = self.cont }};", .{rest_name});
    } else if (init.carriesParentRemaining()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining, .parent_remaining = self.parent_remaining }};", .{rest_name});
    } else if (init.carriesArrayRemaining() and init.carriesContinuation()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining, .cont = self.cont }};", .{rest_name});
    } else if (init.carriesArrayRemaining()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = self.remaining }};", .{rest_name});
    } else if (init.carriesContinuation()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .cont = self.cont }};", .{rest_name});
    } else {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s} }};", .{rest_name});
    }
}

fn codegenWriteReturnCarrySelf(writer: *IndentedWriter, init: WriteNextInit) !void {
    try codegenWriteReturnCarryWithRest(writer, init, "self.rest");
}

fn codegenWriteReturnNewArray(writer: *IndentedWriter, init: WriteNextInit, rest_name: []const u8, count_expr: []const u8) !void {
    if (init.carriesArrayRemaining() and init.carriesContinuation()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = {s}, .parent_remaining = self.remaining, .cont = self.cont }};", .{ rest_name, count_expr });
    } else if (init.carriesArrayRemaining()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = {s}, .parent_remaining = self.remaining }};", .{ rest_name, count_expr });
    } else if (init.carriesContinuation()) {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = {s}, .cont = self.cont }};", .{ rest_name, count_expr });
    } else {
        try writer.println("return .{{ .buffer = self.buffer, .rest = {s}, .remaining = {s} }};", .{ rest_name, count_expr });
    }
}

fn nestedWriteTypeName(allocator: std.mem.Allocator, owner_name: []const u8, field_name: []const u8) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, field_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "write__{s}__{s}", .{ owner_name, sanitized });
}

fn namedWriteFunctionName(allocator: std.mem.Allocator, type_name: []const u8) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, type_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "write_type__{s}", .{sanitized});
}

fn namedSkipFunctionName(allocator: std.mem.Allocator, type_name: []const u8) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, type_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "skip_type__{s}", .{sanitized});
}

fn isNamedWriteTarget(type_name: []const u8) bool {
    const names = [_][]const u8{
        "ArmorTrimMaterial",
        "ArmorTrimPattern",
        "chat_session",
        "command_node",
        "DataComponentMatchers",
        "ExactComponentMatcher",
        "game_profile",
        "HashedSlot",
        "IDSet",
        "ItemBlockPredicate",
        "ItemBlockProperty",
        "ItemBookPage",
        "ItemConsumeEffect",
        "ItemEffectDetail",
        "ItemFireworkExplosion",
        "ItemPotionEffect",
        "ItemSoundEvent",
        "ItemSoundHolder",
        "ItemWrittenBookPage",
        "RecipeDisplay",
        "Slot",
        "SlotComponent",
        "SlotDisplay",
        "UntrustedSlot",
        "UntrustedSlotComponent",
    };
    for (names) |name| {
        if (std.mem.eql(u8, type_name, name)) return true;
    }
    return false;
}

fn switchCaseMethodName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const sanitized = try sanitizeTypeNamePart(allocator, value);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "case_{s}", .{sanitized});
}

fn writeCursorNameAlloc(allocator: std.mem.Allocator, cursor: ?*Cursor) ![]const u8 {
    if (cursor) |c| {
        return std.fmt.allocPrint(allocator, "write__{s}", .{c.name});
    }
    return std.fmt.allocPrint(allocator, "protocol_support.FinalWriteCursor", .{});
}

fn writeSimpleCursorMethodSignature(writer: *IndentedWriter, field_name: []const u8, readType: anytype, next: WriteCursorNameFormatter) !void {
    switch (readType) {
        .native => |native| {
            if (native == .void) {
                try writer.println("pub fn {f}(self: @This()) protocol_support.WriteError!{f} {{", .{ idfmt(field_name), next });
            } else {
                try writer.println("pub fn {f}(self: @This(), field_value: {s}) protocol_support.WriteError!{f} {{", .{ idfmt(field_name), try native.codegenType(), next });
            }
        },
        .pstring => try writer.println("pub fn {f}(self: @This(), field_value: []const u8) protocol_support.WriteError!{f} {{", .{ idfmt(field_name), next }),
        .bitfield => try writer.println("pub fn {f}(self: @This(), field_value: Value) protocol_support.WriteError!{f} {{", .{ idfmt(field_name), next }),
        .bitflags => try writer.println("pub fn {f}(self: @This(), field_value: Value) protocol_support.WriteError!{f} {{", .{ idfmt(field_name), next }),
    }
}

fn codegenNativeWrite(native: NativeType, writer: *IndentedWriter, restName: []const u8) !void {
    if (native == .void) {
        try writer.println("{s} = try protocol_support.write_void({s});", .{ restName, restName });
    } else {
        try writer.println("{s} = try protocol_support.write_{s}({s}, field_value);", .{ restName, @tagName(native), restName });
    }
}

fn writeCursorName(cursor: ?*Cursor) WriteCursorNameFormatter {
    return .{ .cursor = cursor };
}

const WriteCursorNameFormatter = struct {
    cursor: ?*Cursor,

    pub fn format(self: @This(), writer: anytype) !void {
        if (self.cursor) |cursor| {
            try writer.print("write__{s}", .{cursor.name});
        } else {
            try writer.writeAll("protocol_support.FinalWriteCursor");
        }
    }
};

const Cursors = struct {
    allocator: std.mem.Allocator,
    namestack: std.ArrayList([]const u8),

    pub fn allocateCursor(self: *Cursors) !*Cursor {
        const cursor = try self.allocator.create(Cursor);
        var name = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer name.deinit(self.allocator);
        for (0.., self.namestack.items) |i, part| {
            if (i > 0) try name.appendSlice(self.allocator, "__");
            try name.appendSlice(self.allocator, part);
        }
        cursor.name = try std.fmt.allocPrint(self.allocator, "{s}", .{name.items});
        cursor.fieldName = self.namestack.getLast();
        return cursor;
    }

    pub fn pushName(self: *Cursors, name: []const u8) !void {
        try self.namestack.append(self.allocator, name);
    }

    pub fn popName(self: *Cursors) void {
        _ = self.namestack.pop();
    }

    pub fn init(allocator: std.mem.Allocator) !Cursors {
        return .{
            .allocator = allocator,
            .namestack = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }
};

fn readJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(std.json.Value) {
    const data = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(data);

    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .allocate = .alloc_always },
    );
}

fn expectObject(json: std.json.Value) !std.json.ObjectMap {
    switch (json) {
        .object => |obj| {
            return obj;
        },
        else => {
            return error.ExpectedObject;
        },
    }
}

fn expectArray(json: std.json.Value) !std.json.Array {
    switch (json) {
        .array => |array| {
            return array;
        },
        else => {
            return error.ExpectedArray;
        },
    }
}

fn expectString(json: std.json.Value) ![]const u8 {
    switch (json) {
        .string => |str| {
            return str;
        },
        else => {
            return error.ExpectedString;
        },
    }
}

fn expectInteger(json: std.json.Value) !i64 {
    switch (json) {
        .integer => |integer| {
            return integer;
        },
        else => {
            return error.ExpectedInteger;
        },
    }
}

fn expectBoolean(json: std.json.Value) !bool {
    switch (json) {
        .bool => |boolean| {
            return boolean;
        },
        else => {
            return error.ExpectedBoolean;
        },
    }
}

fn expectGet(object: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return object.get(key) orelse {
        return error.MissingKey;
    };
}

fn equalsString(json: std.json.Value, str: []const u8) bool {
    return switch (json) {
        .string => |s| std.mem.eql(u8, s, str),
        else => false,
    };
}

fn isString(json: std.json.Value) ?[]const u8 {
    return switch (json) {
        .string => |str| str,
        else => null,
    };
}

fn isConstructor(json: std.json.Value) ?struct { name: []const u8, arg: std.json.Value } {
    switch (json) {
        .array => |array| {
            if (array.items.len != 2) {
                return null;
            }
            const name = expectString(array.items[0]) catch {
                return null;
            };
            return .{
                .name = name,
                .arg = array.items[1],
            };
        },
        else => {
            return null;
        },
    }
}

pub fn idfmt(input: []const u8) IdFormatter {
    return IdFormatter{ .input = input };
}

pub const IdFormatter = struct {
    input: []const u8,

    fn isKeyword(s: []const u8) bool {
        const keywords = [_][]const u8{
            "const",
            "var",
            "fn",
            "struct",
            "union",
            "enum",
            "if",
            "else",
            "while",
            "for",
            "break",
            "continue",
            "return",
            "try",
            "catch",
            "pub",
            "extern",
            "comptime",
            "async",
            "await",
            "test",
            "error",
            "orelse",
            "switch",
            "usingnamespace",
            "noalias",
            "volatile",
            "linksection",
            "threadlocal",
            "align",
            "export",
            "u8",
            "u16",
            "u32",
            "u64",
            "i8",
            "i16",
            "i32",
            "i64",
            "bool",
            "f32",
            "f64",
            "void",
            "type",
            "true",
            "false",
            "null",
        };

        for (keywords) |keyword| {
            if (std.mem.eql(u8, keyword, s)) {
                return true;
            }
        }
        return false;
    }

    fn isIdentifier(s: []const u8) bool {
        if (s.len == 0) return false;
        if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
        for (s[1..]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        }
        return true;
    }

    pub fn format(
        self: @This(),
        writer: anytype,
    ) !void {
        if (@This().isKeyword(self.input) or !@This().isIdentifier(self.input)) {
            try writer.print("@\"{s}\"", .{self.input});
        } else {
            try writer.writeAll(self.input);
        }
    }
};

fn printIndent(writer: *std.Io.Writer, level: usize) !void {
    for (0..level) |_| {
        try writer.print("    ", .{});
    }
}

const IndentedWriter = struct {
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    level: usize = 0,
    temp_index: usize = 0,

    pub fn println(self: *IndentedWriter, comptime fmt: []const u8, args: anytype) !void {
        try printIndent(self.writer, self.level);
        try self.writer.print(fmt, args);
        _ = try self.writer.write("\n");
    }

    pub fn indent(self: *IndentedWriter) void {
        self.level += 1;
    }

    pub fn unindent(self: *IndentedWriter) void {
        self.level -= 1;
    }

    pub fn nextId(self: *IndentedWriter) usize {
        const result = self.temp_index;
        self.temp_index += 1;
        return result;
    }
};
