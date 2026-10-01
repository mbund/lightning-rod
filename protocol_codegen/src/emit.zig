const std = @import("std");
const s = @import("schema.zig");

pub const Emitter = struct {
    graph: *const s.Graph,
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    protocol_number: i32,
    packets: []?Packet = &.{},
    fingerprints: []?[32]u8 = &.{},
    cursor_id: s.Id = s.none,
    payloads: []bool = &.{},
    restricted: ?struct { root: s.Id, field: usize, branch: usize } = null,

    const Packet = struct { name: []const u8, phase: []const u8, direction: []const u8, fingerprint: [32]u8 };

    pub fn run(self: *Emitter) !void {
        self.packets = try self.allocator.alloc(?Packet, self.graph.nodes.items.len);
        @memset(self.packets, null);
        self.fingerprints = try self.allocator.alloc(?[32]u8, self.graph.nodes.items.len);
        @memset(self.fingerprints, null);
        self.payloads = try self.allocator.alloc(bool, self.graph.nodes.items.len);
        @memset(self.payloads, false);
        for (self.graph.nodes.items, 0..) |node, id| {
            if (node.kind != .container or node.name.len == 0) continue;
            for (node.fields, 0..) |_, field| if (try self.restrictable(@intCast(id), field)) |choice| {
                for (choice.branches) |branch| self.payloads[try self.graph.resolve(branch.node)] = true;
            };
        }
        for (self.graph.scopes.items[1..]) |scope| {
            const envelope_id = scope.types.get("packet") orelse continue;
            const packet_envelope = self.graph.nodes.items[try self.graph.resolve(envelope_id)];
            if (packet_envelope.kind != .container or packet_envelope.fields.len != 2) return error.InvalidPacketEnvelope;
            const choice = self.graph.nodes.items[try self.graph.resolve(packet_envelope.fields[1].node)];
            const dot = std.mem.indexOfScalar(u8, scope.name, '.').?;
            for (choice.branches) |branch| {
                const id = try self.graph.resolve(branch.node);
                if (self.packets[id]) |previous| {
                    std.log.err("packet cursor shared by {s}.{s}.{s} and {s}.{s}", .{ previous.phase, previous.direction, previous.name, scope.name, branch.name });
                    return error.SharedPacketCursor;
                }
                self.packets[id] = .{
                    .name = branch.name,
                    .phase = scope.name[0..dot],
                    .direction = scope.name[dot + 1 ..],
                    .fingerprint = try self.layoutFingerprint(id),
                };
            }
        }
        try self.out.writeAll(
            \\const std = @import("std");
            \\const wire = @import("protocol_support");
            \\const c = wire.cursor;
            \\const scanner = wire.scan;
            \\
        );
        try self.out.print("pub const protocol_number: i32 = {};\n", .{self.protocol_number});

        for (self.graph.nodes.items, 0..) |node, id| {
            if (node.kind == .scalar)
                try self.scalar(@intCast(id), node);

            if (node.root == id) {
                try self.out.print("const Context_{} = struct {{\n", .{id});

                for (self.graph.bindings.items, 0..) |binding, index|
                    if (self.graph.nodes.items[binding.owner].root == id)
                        try self.out.print("v_{}: i128 = 0,\n", .{index});

                try self.out.writeAll("};\n");
            }
        }

        try self.scanTable();
        try self.layoutTable();
        try self.tagTable();

        for ([_][]const u8{ "read", "write" }) |mode| {
            try self.out.print("const {s} = struct {{\n", .{if (std.mem.eql(u8, mode, "write")) "Writers" else "Readers"});
            for (self.graph.nodes.items, 0..) |node, id| {
                if (node.kind == .constructor or node.kind == .alias)
                    continue;

                try self.cursor(@intCast(id), node, mode);
            }
            if (std.mem.eql(u8, mode, "write")) {
                for (self.graph.nodes.items, 0..) |node, id| {
                    if (node.name.len == 0 or node.kind != .container) continue;
                    for (node.fields, 0..) |_, field| {
                        const choice = (try self.restrictable(@intCast(id), field)) orelse continue;
                        for (choice.branches, 0..) |_, branch| {
                            self.restricted = .{ .root = @intCast(id), .field = field, .branch = branch };
                            try self.cursor(@intCast(id), node, mode);
                        }
                    }
                }
                self.restricted = null;
            }
            try self.out.writeAll("};\n");
        }

        try self.out.writeAll("pub const NamedWriters = struct {\n");
        for (self.graph.nodes.items, 0..) |node, id| {
            _ = node;
            if (try self.isDestination(@intCast(id)))
                try self.out.print("pub const @\"{s}\" = Writers.write_{};\n", .{ try self.schemaName(@intCast(id)), id });
        }
        try self.out.writeAll("};\npub fn namedWriter(comptime name: []const u8) ?type { return if (@hasDecl(NamedWriters, name)) @field(NamedWriters, name) else null; }\n");

        for (self.graph.scopes.items, 0..) |scope, scope_index| {
            if (scope_index != 0) {
                const dot = std.mem.indexOfScalar(u8, scope.name, '.').?;

                if (scope_index % 2 == 1)
                    try self.out.print("pub const {s} = struct {{\n", .{scope.name[0..dot]});

                try self.out.print("pub const {s} = struct {{\n", .{scope.name[dot + 1 ..]});
            }

            var names = scope.types.iterator();

            while (names.next()) |entry| {
                if (self.graph.nodes.items[entry.value_ptr.*].native)
                    continue;

                const id = try self.graph.resolve(entry.value_ptr.*);
                if (self.graph.nodes.items[id].kind == .constructor)
                    continue;

                const fingerprint = try self.layoutFingerprint(id);
                try self.out.writeAll("pub const @\"");
                try self.out.writeAll(entry.key_ptr.*);
                try self.out.writeAll("\" = struct { pub const layout_fingerprint = [_]u8{");
                for (fingerprint) |byte| try self.out.print("{},", .{byte});

                try self.out.print(
                    \\}};
                    \\    pub const Reader = Readers.read_{};
                    \\    pub const Writer = Writers.write_{};
                    \\    pub fn read(bytes: []const u8) Reader {{
                    \\        return .{{ ._cursor = .{{ .buffer = bytes, .rest = bytes, .protocol_number = {} }} }};
                    \\    }}
                    \\    pub fn write(bytes: []u8) Writer {{
                    \\        return .{{ ._cursor = .{{ .buffer = bytes, .rest = bytes, .protocol_number = {}, .tags = case_tags }} }};
                    \\    }}
                    \\
                , .{ id, id, self.protocol_number, self.protocol_number });
                if (try self.isDestination(id))
                    try self.out.print("pub const Destination = c.Destination(\"{s}\");\npub const Completion = Destination.Done;\n", .{try self.schemaName(id)});
                try self.out.writeAll("pub const cases = struct {\n");
                const node = self.graph.nodes.items[id];
                for (node.fields, 0..) |field, field_index| {
                    const choice = (try self.restrictable(id, field_index)) orelse continue;
                    try self.out.print("pub const @\"{s}\" = struct {{\n", .{field.name});
                    const selector = self.graph.bindings.items[choice.selector.field];
                    try self.out.print("pub const tag_field = \"{s}\";\npub const tagged_record = {};\npub const Tag = enum(i128) {{\n", .{ node.fields[selector.field].name, node.fields.len == 2 and selector.field == 0 and field_index == 1 });
                    for (choice.branches) |branch| try self.out.print("@\"{s}\" = {},\n", .{ branch.name, branch.value });
                    try self.out.writeAll("};\n");
                    for (choice.branches, 0..) |branch, branch_index| {
                        self.restricted = .{ .root = id, .field = field_index, .branch = branch_index };
                        const name = try self.typeName("write", id, 0);
                        try self.out.print(
                            \\pub const @"{s}" = struct {{
                            \\pub const Writer = Writers.{s};
                            \\pub fn write(bytes: []u8) @This().Writer {{ return .{{ ._cursor = .{{ .buffer = bytes, .rest = bytes, .protocol_number = {}, .tags = case_tags }} }}; }}
                            \\
                        , .{ branch.name, name, self.protocol_number });
                        const payload = try self.graph.resolve(branch.node);
                        try self.out.print(
                            \\pub const Payload = struct {{
                            \\pub const Reader = Readers.read_{};
                            \\pub const Writer = Writers.write_{};
                            \\pub fn read(bytes: []const u8) @This().Reader {{ return .{{ ._cursor = .{{ .buffer = bytes, .rest = bytes, .protocol_number = protocol_number }} }}; }}
                            \\}};
                            \\
                        , .{ payload, payload });
                        try self.out.writeAll("};\n");
                    }
                    self.restricted = null;
                    try self.out.writeAll("};\n");
                }
                try self.out.writeAll("}; };\n");
            }

            if (scope_index != 0) {
                try self.envelope(scope);
                try self.out.writeAll("};\n");

                if (scope_index % 2 == 0)
                    try self.out.writeAll("};\n");
            }
        }
    }

    fn cursor(self: *Emitter, id: s.Id, node: s.Node, mode: []const u8) !void {
        self.cursor_id = id;
        const fields = if (node.kind == .container) node.fields else &.{};
        const steps = @max(1, fields.len);
        const end = try self.fmt("{s}.Done", .{try self.typeName(mode, id, 0)});

        for (0..steps) |step| {
            const name = try self.typeName(mode, id, step);
            const next = if (step + 1 < steps) try self.typeName(mode, id, step + 1) else end;
            try self.out.print(
                \\pub const {s} = struct {{
                \\pub const Context = Context_{};
                \\_cursor: c.State(.{s}),
                \\_context: Context = .{{}},
                \\
            , .{ name, node.root, mode });

            if (step == 0) {
                try self.out.print("pub const requires_parent_context = {};\n", .{try self.requiresParentContext(id)});
                try self.out.print("pub const schema_nodes = &layout_nodes;\npub const schema_id = {};\npub const wire_type_name = \"{s}\";\n", .{ id, try self.schemaName(id) });
                try self.out.writeAll("pub fn requireCompatible(comptime Actual: type) void { c.layout.requireCompatible(@This(), Actual); }\n");
                if (self.restricted) |restricted| {
                    const choice_id = try self.graph.resolve(node.fields[restricted.field].node);
                    const branch = self.graph.nodes.items[choice_id].branches[restricted.branch];
                    try self.out.print("pub const restricted_case: ?c.layout.Case = .{{ .choice = {}, .field = \"{s}\", .name = \"{s}\" }};\n", .{ choice_id, node.fields[restricted.field].name, branch.name });
                } else try self.out.writeAll("pub const restricted_case: ?c.layout.Case = null;\n");
            }

            if (step == 0 and ((node.root == id and node.name.len != 0) or self.payloads[id]) and self.packets[id] == null) {
                const fingerprint = try self.layoutFingerprint(id);
                try self.out.print("pub const protocol_number: i32 = {};\npub const cursor_mode = \"{s}\";\npub const layout_fingerprint = [_]u8{{", .{ self.protocol_number, mode });
                for (fingerprint) |byte| try self.out.print("{},", .{byte});
                try self.out.writeAll("};\n");
            }
            if (step == 0 and !(node.root == id and node.name.len != 0) and !self.payloads[id] and self.packets[id] == null)
                try self.out.print("pub const protocol_number: i32 = {};\npub const cursor_mode = \"{s}\";\n", .{ self.protocol_number, mode });

            if (step == 0) if (self.packets[id]) |packet| {
                try self.out.print("pub const protocol_number: i32 = {};\npub const packet_name = \"{s}\";\npub const phase = \"{s}\";\npub const direction = \"{s}\";\npub const cursor_mode = \"{s}\";\npub const layout_fingerprint = [_]u8{{", .{ self.protocol_number, packet.name, packet.phase, packet.direction, mode });
                for (packet.fingerprint) |byte| try self.out.print("{},", .{byte});
                try self.out.writeAll("};\n");
                try self.out.writeAll("pub fn protocolNumber(self: @This()) i32 { return self._cursor.protocol_number; }\n");
            };

            if (step == 0) try self.out.print("pub const Done = c.End(@This(), .{s});\n", .{mode});
            if (step == 0 and std.mem.eql(u8, mode, "read")) {
                try self.out.writeAll(
                    \\pub fn scan(self: @This()) c.Error!Done {
                    \\const variables = [_]scanner.Variable{
                    \\
                );

                for (self.graph.bindings.items, 0..) |binding, binding_id|
                    if (self.graph.nodes.items[binding.owner].root == node.root)
                        try self.out.print(".{{ .id = {}, .value = self._context.v_{} }},\n", .{ binding_id, binding_id });

                try self.out.print(
                    \\}};
                    \\var _state = self._cursor;
                    \\_state.rest, _state.value = try scanner.run(&scan_nodes, {}, _state.rest, &variables, _state.first_mask);
                    \\_state.first_mask = 255;
                    \\return .{{ ._cursor = _state, ._context = self._context }};
                    \\}}
                    \\
                , .{id});
            }

            switch (node.kind) {
                .container => {
                    if (self.restricted) |restricted| {
                        const choice = self.graph.nodes.items[try self.graph.resolve(node.fields[restricted.field].node)];
                        const selector = self.graph.bindings.items[choice.selector.field];
                        const branch = choice.branches[restricted.branch];
                        if (step == selector.field) {
                            const codec = self.graph.nodes.items[try self.graph.resolve(fields[step].node)].codec;
                            try self.out.print(
                                \\pub fn @"{s}"(self: @This()) c.Error!{s} {{
                                \\var state = self._cursor;
                                \\state.rest = try wire.write_{s}(state.rest, @intCast(try state.tag({})));
                                \\var next_context = self._context;
                                \\next_context.v_{} = {};
                                \\return .{{ ._cursor = state, ._context = next_context }};
                                \\}}
                                \\
                            , .{ fields[step].name, next, codec, try self.tagKey(node, fields[restricted.field].name, branch.name), choice.selector.field, branch.value });
                            try self.out.writeAll("};\n");
                            continue;
                        }
                        if (step == restricted.field) {
                            try self.emitEntry(mode, branch.node, fields[step].name, next, fields[step].binding, .{});
                            try self.out.writeAll("};\n");
                            continue;
                        }
                    }
                    if (fields.len == 0) {
                        try self.out.print("pub fn complete(self: @This()) {s} {{ return .{{ ._cursor = self._cursor, ._context = self._context }}; }}\n", .{end});
                        try self.out.print("pub fn finish(self: @This()) {s} {{ return self.complete().finish(); }}\n", .{if (std.mem.eql(u8, mode, "read")) "c.Error!void" else "[]u8"});
                    } else try self.emitEntry(mode, fields[step].node, fields[step].name, next, fields[step].binding, .{});
                },
                .optional => {
                    if (std.mem.eql(u8, mode, "write")) {
                        try self.out.print(
                            \\pub fn none(self: @This()) c.Error!{s} {{ var _state = self._cursor;
                            \\_state.rest = try wire.write_bool(_state.rest, false);
                            \\_state.value = -1;
                            \\return .{{ ._cursor = _state, ._context = self._context }};
                            \\}}
                            \\
                        , .{end});
                        try self.emitEntry(mode, node.child, "some", end, s.none, .{
                            .code = "_state.rest = try wire.write_bool(_state.rest, true);",
                            .writes = true,
                        });
                    } else {
                        const child = try self.referenceType(mode, try self.graph.resolve(node.child));
                        const gate_type = try self.gate(child, end, mode, s.none);
                        try self.out.print(
                            \\pub fn value(self: @This()) c.Error!union(enum) {{ none: {s}, some: {s} }} {{ var _state = self._cursor;
                            \\const present, const rest = try wire.read_bool(_state.rest);
                            \\_state.rest = rest;
                            \\if (!present) {{ _state.value = -1;
                            \\return .{{ .none = .{{ ._cursor = _state, ._context = self._context }} }};
                            \\}} return .{{ .some = {s} }};
                            \\}}
                            \\
                        , .{ end, gate_type, try self.gateInit(child, end) });
                    }
                },
                .choice => {
                    const selector = try self.selectorExpr(node.selector);

                    for (node.branches) |branch|
                        try self.emitEntry(mode, branch.node, try self.fmt("case_{s}", .{branch.name}), end, s.none, .{
                            .code = try self.fmt("if ({s} != {}) return error.InvalidTag;", .{ selector, branch.value }),
                        });

                    var checks: std.Io.Writer.Allocating = .init(self.allocator);

                    for (node.branches) |branch|
                        try checks.writer.print("if ({s} == {}) return error.InvalidTag;\n", .{ selector, branch.value });

                    if (node.fallback != s.none)
                        try self.emitEntry(mode, node.fallback, "case_default", end, s.none, .{ .code = checks.written() });

                    if (std.mem.eql(u8, mode, "read")) {
                        if (node.branches.len == 0 and node.fallback == s.none) {
                            try self.out.writeAll(
                                \\pub fn select(_: @This()) c.Error!noreturn { return error.InvalidTag;
                                \\}
                                \\};
                                \\
                            );
                            continue;
                        }

                        try self.out.writeAll("pub fn select(self: @This()) c.Error!union(enum) {\n");

                        for (node.branches) |branch|
                            try self.out.print("@\"{s}\": {s},\n", .{
                                branch.name,
                                try self.gate(try self.referenceType(mode, try self.graph.resolve(branch.node)), end, mode, s.none),
                            });

                        const fallback = if (node.fallback == s.none) "" else try self.referenceType(mode, try self.graph.resolve(node.fallback));

                        if (node.fallback != s.none)
                            try self.out.print("default: {s},\n", .{try self.gate(fallback, end, mode, s.none)});

                        try self.out.writeAll("} { const _state = self._cursor;\n");

                        for (node.branches) |branch|
                            try self.out.print("if ({s} == {}) return .{{ .@\"{s}\" = {s} }};\n", .{
                                selector,
                                branch.value,
                                branch.name,
                                try self.gateInit(try self.referenceType(mode, try self.graph.resolve(branch.node)), end),
                            });

                        if (node.fallback != s.none)
                            try self.out.print("return .{{ .default = {s} }}; }}\n", .{try self.gateInit(fallback, end)})
                        else
                            try self.out.writeAll("return error.InvalidTag; }\n");
                    }
                },
                .holder, .holder_set => try self.holder(mode, node, end),
                .scalar => {
                    try self.out.print("pub const Value = Scalar_{}.Value;\n", .{id});
                    try self.emitEntry(mode, id, "value", end, s.none, .{});
                },
                .array => try self.emitEntry(mode, id, "value", end, s.none, .{}),
                else => unreachable,
            }

            try self.out.writeAll("};\n");
        }
    }

    fn emitEntry(
        self: *Emitter,
        mode: []const u8,
        original: s.Id,
        method: []const u8,
        next: []const u8,
        capture: s.Id,
        prefix: struct {
            code: []const u8 = "",
            writes: bool = false,
        },
    ) !void {
        const id = try self.graph.resolve(original);
        const node = self.graph.nodes.items[id];
        const reading = std.mem.eql(u8, mode, "read");
        if (id != self.cursor_id and node.name.len != 0 and node.kind != .scalar) {
            const entry = try self.referenceType(mode, id);
            try self.out.print(
                \\pub fn @"{s}"(self: @This()) c.Error!{s} {{
                \\{s} _state = self._cursor;
                \\{s}
                \\return {s};
                \\}}
                \\
            , .{ method, try self.gate(entry, next, mode, capture), if (prefix.writes) "var" else "const", prefix.code, try self.gateInit(entry, next) });
            return;
        }
        const scalar_node = node.kind == .scalar;
        const sequence = node.kind == .array;
        const counted = sequence and (node.count == .wire or node.count == .sentinel or node.count == .high_bit);
        const child = try self.referenceType(mode, if (sequence) try self.graph.resolve(node.child) else id);
        const result = blk: {
            if (scalar_node) {
                if (reading)
                    break :blk try self.fmt("struct {{ Scalar_{}.Value, {s} }}", .{ id, next });

                break :blk next;
            }

            if (sequence)
                break :blk try self.sequenceType(child, next, mode, node.count);

            break :blk try self.gate(child, next, mode, capture);
        };
        const argument = blk: {
            if (reading)
                break :blk "";

            if (scalar_node and !std.mem.eql(u8, node.codec, "void"))
                break :blk try self.fmt(", field_value: Scalar_{}.Value", .{id});

            if (counted)
                break :blk ", length: usize";

            break :blk "";
        };
        if (!reading and scalar_node and capture == s.none and std.mem.eql(u8, node.codec, "restBuffer")) {
            try self.out.print(
                \\pub fn @"{s}Uninitialized"(self: @This(), length: usize) c.Error!struct {{ []u8, {s} }} {{
                \\var state = self._cursor;
                \\if (length > state.rest.len) return error.EndOfStream;
                \\const reserved = state.rest[0..length];
                \\state.rest = state.rest[length..];
                \\state.value = 0;
                \\state.first_mask = 255;
                \\return .{{ reserved, .{{ ._cursor = state, ._context = c.context({s}.Context, self._context) }} }};
                \\}}
            , .{ method, next, next });
        }
        try self.out.print("pub fn @\"{s}\"(self: @This(){s}) c.Error!{s} {{\n", .{ method, argument, result });
        const mutable = scalar_node or prefix.writes or (sequence and node.count == .wire);
        try self.out.print(
            \\{s} _state = self._cursor;
            \\{s}
            \\
        , .{ if (mutable) "var" else "const", prefix.code });

        if (scalar_node) {
            const length = if (node.count == .field) try self.fmt("try wire.count_to_usize({s})", .{try self.selectorExpr(node.count.field)}) else "0";

            if (reading) {
                try self.out.print("const field_value, const rest, const captured = try Scalar_{}.read(_state.rest, {s}, _state.first_mask);\n", .{ id, length });
            } else {
                try self.out.print("const rest, const captured = try Scalar_{}.write(_state.rest, {s}, {s});\n", .{ id, if (std.mem.eql(u8, node.codec, "void")) "{}" else "field_value", length });
            }

            try self.out.writeAll("_state.rest = rest; _state.value = captured; _state.first_mask = 255;\n");

            if (capture != s.none) {
                try self.out.print("var next_context = c.context({s}.Context, self._context); next_context.v_{} = captured;\n", .{ next, capture });
            } else {
                try self.out.print("const next_context = c.context({s}.Context, self._context);\n", .{next});
            }

            try self.out.print("return {s}.{{ ._cursor = _state, ._context = next_context }}{s};\n", .{ if (reading) ".{ field_value, " else "", if (reading) " }" else "" });
        } else if (sequence) {
            switch (node.count) {
                .wire => |codec| {
                    if (reading) try self.out.print(
                        \\const count_value, const rest = try wire.read_{s}(_state.rest);
                        \\_state.rest = rest;
                        \\const length = try c.count(count_value);
                        \\
                    , .{codec}) else try self.out.print(
                        \\_ = try c.count(length);
                        \\_state.rest = try wire.write_{s}(_state.rest, std.math.cast({s}, length) orelse return error.LengthOverflow);
                        \\
                    , .{ codec, try valueType(self.allocator, codec) });
                },
                .fixed => |n| try self.out.print("const length: usize = {};\n", .{n}),
                .field => |selector| try self.out.print("const length = try c.count({s});\n", .{try self.selectorExpr(selector)}),
                .sentinel, .high_bit => {
                    if (reading)
                        try self.out.writeAll("const length = wire.maximum_sequence_elements;\n")
                    else
                        try self.out.writeAll("_ = try c.count(length);\n");

                    if (!reading and node.count == .high_bit)
                        try self.out.writeAll("if (length == 0) return error.MissingItems;\n");
                },
            }

            try self.out.print(
                \\return .{{ .next_value = .{{ ._cursor = _state, ._context = c.context({s}.Context, self._context) }}, .child_context = c.context({s}.Context, self._context), .remaining = length, .start = self._cursor.buffer.len - self._cursor.rest.len }};
                \\
            , .{ next, child });
        } else try self.out.print("return {s};\n", .{try self.gateInit(child, next)});
        try self.out.writeAll("}\n");
    }

    fn holder(self: *Emitter, mode: []const u8, node: s.Node, end: []const u8) !void {
        const set = node.kind == .holder_set;
        const first = node.fields[0];
        const second = node.fields[1];
        const child = try self.referenceType(mode, try self.graph.resolve(second.node));

        if (std.mem.eql(u8, mode, "write")) {
            if (!set) try self.out.print(
                \\pub fn @"{s}"(self: @This(), id: i32) c.Error!{s} {{ if (id <= 0) return error.InvalidTag;
                \\var _state = self._cursor;
                \\_state.rest = try wire.write_varint(_state.rest, id);
                \\return .{{ ._cursor = _state, ._context = self._context }};
                \\}}
                \\
            , .{ first.name, end }) else try self.emitEntry(mode, first.node, first.name, end, s.none, .{
                .code = "_state.rest = try wire.write_varint(_state.rest, 0);",
                .writes = true,
            });

            if (!set) try self.emitEntry(mode, second.node, second.name, end, s.none, .{
                .code = "_state.rest = try wire.write_varint(_state.rest, 0);",
                .writes = true,
            }) else {
                try self.out.print(
                    \\pub fn @"{s}"(self: @This(), length: usize) c.Error!{s} {{ _ = try c.count(length);
                    \\var _state = self._cursor;
                    \\_state.rest = try wire.write_count(_state.rest, i32, length + 1);
                    \\return .{{ .next_value = .{{ ._cursor = _state, ._context = self._context }}, .child_context = c.context({s}.Context, self._context), .remaining = length }};
                    \\}}
                    \\
                , .{ second.name, try self.sequenceType(child, end, mode, .{ .fixed = 0 }), child });
            }
        } else {
            const base = if (set) try self.referenceType(mode, try self.graph.resolve(first.node)) else "";
            const base_type = if (set) try self.gate(base, end, mode, s.none) else try self.fmt("struct {{ id: i32, next: {s} }}", .{end});
            const other_type = if (set) try self.sequenceType(child, end, mode, .{ .fixed = 0 }) else try self.gate(child, end, mode, s.none);
            try self.out.print(
                \\pub fn value(self: @This()) c.Error!union(enum) {{ @"{s}": {s}, @"{s}": {s} }} {{ var _state = self._cursor;
                \\const id, const rest = try wire.read_varint(_state.rest);
                \\_state.rest = rest;
                \\if (id < 0) return error.InvalidTag;
                \\
            , .{ first.name, base_type, second.name, other_type });

            if (set) {
                try self.out.print(
                    \\if (id == 0) return .{{ .@"{s}" = {s} }};
                    \\return .{{ .@"{s}" = .{{ .next_value = .{{ ._cursor = _state, ._context = self._context }}, .child_context = c.context({s}.Context, self._context), .remaining = try c.count(id - 1), .start = self._cursor.buffer.len - self._cursor.rest.len }} }};
                    \\
                , .{ first.name, try self.gateInit(base, end), second.name, child });
            } else try self.out.print(
                \\if (id != 0) return .{{ .@"{s}" = .{{ .id = id, .next = .{{ ._cursor = _state, ._context = self._context }} }} }};
                \\return .{{ .@"{s}" = {s} }};
                \\
            , .{ first.name, second.name, try self.gateInit(child, end) });
            try self.out.writeAll("}\n");
        }
    }

    fn scalar(self: *Emitter, id: s.Id, node: s.Node) !void {
        const bytes = std.mem.eql(u8, node.codec, "buffer") or std.mem.eql(u8, node.codec, "pstring");
        const has_members = node.members.len != 0;
        try self.out.print("const Scalar_{} = struct {{\npub const Value = ", .{id});

        if (has_members) {
            try self.out.writeAll("struct {\n");

            for (node.members) |member| try self.out.print("@\"{s}\": {s}{s},\n", .{ member.name, try self.memberType(member), if (member.bits == 1 and !member.signed) " = false" else "" });
            try self.out.writeAll("};\n");
        } else try self.out.print("{s};\n", .{if (bytes) "[]const u8" else try valueType(self.allocator, node.codec)});
        try self.out.writeAll("pub fn read(input: []const u8, length: usize, first_mask: u8) c.Error!struct { Value, []const u8, i128 } {\n");

        if (!(bytes and node.count == .field)) try self.out.writeAll("_ = length;\n");
        const byte = !has_members and (std.mem.eql(u8, node.codec, "u8") or std.mem.eql(u8, node.codec, "i8"));

        if (!byte) try self.out.writeAll("_ = first_mask;\n");

        if (bytes) {
            switch (node.count) {
                .wire => |codec| try self.out.print(
                    \\const size, const prefix = try wire.read_{s}(input);
                    \\const value, const rest = try wire.read_buffer_exact(prefix, try wire.count_to_usize(size));
                    \\
                , .{codec}),
                .fixed => |n| try self.out.print("const value, const rest = try wire.read_buffer_exact(input, {});\n", .{n}),
                .field => try self.out.writeAll("const value, const rest = try wire.read_buffer_exact(input, length);\n"),
                else => return error.InvalidByteCount,
            }
        } else if (std.mem.eql(u8, node.codec, "packed_bits")) try self.out.print("const raw, const rest = try wire.read_packed_bits(input, {});\n", .{node.count.fixed}) else try self.out.print("const {s}, const rest = try wire.read_{s}(input);\n", .{ if (has_members or byte) "raw" else "value", node.codec });

        if (has_members) {
            try self.out.writeAll("const value: Value = .{\n");

            for (node.members) |member| try self.out.print(".@\"{s}\" = {s}(c.select(@intCast(raw), {}, {}, {})){s},\n", .{ member.name, if (member.bits == 1 and !member.signed) "" else "@intCast", member.shift, member.bits, member.signed, if (member.bits == 1 and !member.signed) " != 0" else "" });
            try self.out.writeAll("};\n");
        } else if (byte) try self.out.print("const value: Value = {s}(@as(u8, @bitCast(raw)) & first_mask);\n", .{if (std.mem.eql(u8, node.codec, "i8")) "@bitCast" else "@intCast"});
        try self.out.print(
            \\return .{{ value, rest, {s} }};
            \\}}
            \\
        , .{if (has_members) "@intCast(raw)" else if (std.mem.eql(u8, node.codec, "bool")) "@intFromBool(value)" else if (numeric(node.codec)) "@intCast(value)" else "0"});
        try self.out.writeAll("pub fn write(output: []u8, value: Value, length: usize) c.Error!struct { []u8, i128 } {\n");

        if (!(bytes and node.count == .field)) try self.out.writeAll("_ = length;\n");
        if (has_members) {
            try self.out.writeAll("var raw: u64 = 0;\n");

            for (node.members) |member| {
                if (member.bits == 1 and !member.signed) try self.out.print("raw |= @as(u64, @intFromBool(value.@\"{s}\")) << {};\n", .{ member.name, member.shift }) else {
                    const min: i128 = if (member.signed) -(@as(i128, 1) << (member.bits - 1)) else 0;
                    const max = (@as(i128, 1) << (member.bits - @intFromBool(member.signed))) - 1;
                    try self.out.print(
                        \\if (@as(i128, value.@"{s}") < {} or @as(i128, value.@"{s}") > {}) return error.InvalidTag;
                        \\raw |= (@as(u64, @truncate(@as(u128, @bitCast(@as(i128, value.@"{s}"))))) & wire.bit_mask({})) << {};
                        \\
                    , .{ member.name, min, member.name, max, member.name, member.bits, member.shift });
                }
            }
        }

        if (bytes) {
            switch (node.count) {
                .wire => |codec| try self.out.print(
                    \\const prefix = try wire.write_{s}(output, std.math.cast({s}, value.len) orelse return error.LengthOverflow);
                    \\const rest = try wire.write_bytes(prefix, value);
                    \\
                , .{ codec, try valueType(self.allocator, codec) }),
                .fixed, .field => {
                    const n = if (node.count == .fixed) try self.fmt("{}", .{node.count.fixed}) else "length";
                    try self.out.print("if (value.len != {s}) return error.LengthMismatch; const rest = try wire.write_bytes(output, value);\n", .{n});
                },
                else => unreachable,
            }
        } else if (std.mem.eql(u8, node.codec, "packed_bits")) try self.out.print("const rest = try wire.write_packed_bits(output, {}, raw);\n", .{node.count.fixed}) else if (std.mem.eql(u8, node.codec, "void")) try self.out.writeAll("_ = value; const rest = output;\n") else try self.out.print("const rest = try wire.write_{s}(output, {s});\n", .{ node.codec, if (has_members) "@intCast(raw)" else "value" });
        try self.out.print(
            \\return .{{ rest, {s} }};
            \\}}
            \\}};
            \\
        , .{if (has_members) "@intCast(raw)" else if (std.mem.eql(u8, node.codec, "bool")) "@intFromBool(value)" else if (numeric(node.codec)) "@intCast(value)" else "0"});
    }

    fn scanTable(self: *Emitter) !void {
        for ([_][]const u8{ "varint", "varlong", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64" }) |codec| {
            try self.out.print(
                \\fn count_{s}(bytes: []const u8) c.Error!struct {{ i128, []const u8 }} {{ const n, const rest = try wire.read_{s}(bytes);
                \\return .{{ n, rest }};
                \\}}
                \\
            , .{ codec, codec });
        }

        for (self.graph.nodes.items, 0..) |node, id| if (node.kind == .scalar) {
            try self.out.print(
                \\fn scan_{}(bytes: []const u8, length: usize, mask: u8) c.Error!struct {{ []const u8, i128 }} {{ _, const rest, const value = try Scalar_{}.read(bytes, length, mask);
                \\return .{{ rest, value }};
                \\}}
                \\
            , .{ id, id });
        };

        try self.out.writeAll("const scan_nodes = [_]scanner.Node{\n");

        for (self.graph.nodes.items, 0..) |node, id| {
            switch (node.kind) {
                .scalar => try self.out.print(".{{ .scalar = .{{ .read = scan_{}, .count = {s} }} }},\n", .{ id, try self.scanCount(node.count) }),
                .container => {
                    try self.out.writeAll(".{ .container = &.{\n");

                    for (node.fields) |field| try self.out.print(".{{ .node = {}, .capture = {} }},\n", .{ try self.graph.resolve(field.node), field.binding });
                    try self.out.writeAll("} },\n");
                },
                .array => try self.out.print(".{{ .array = .{{ .child = {}, .count = {s} }} }},\n", .{ try self.graph.resolve(node.child), try self.scanCount(node.count) }),
                .optional => try self.out.print(".{{ .optional = {} }},\n", .{try self.graph.resolve(node.child)}),
                .choice => {
                    try self.out.print(".{{ .choice = .{{ .selector = {s}, .fallback = {}, .branches = &.{{\n", .{ try self.scanSelector(node.selector), if (node.fallback == s.none) s.none else try self.graph.resolve(node.fallback) });

                    for (node.branches) |branch| try self.out.print(".{{ .value = {}, .node = {} }},\n", .{ branch.value, try self.graph.resolve(branch.node) });
                    try self.out.writeAll("} } },\n");
                },
                .holder => try self.out.print(".{{ .holder = {} }},\n", .{try self.graph.resolve(node.fields[1].node)}),
                .holder_set => try self.out.print(".{{ .holder_set = .{{ .base = {}, .child = {} }} }},\n", .{ try self.graph.resolve(node.fields[0].node), try self.graph.resolve(node.fields[1].node) }),
                .alias, .constructor => try self.out.writeAll(".invalid,\n"),
                .pending => unreachable,
            }
        }

        try self.out.writeAll("};\n");
    }

    fn scanSelector(self: *Emitter, selected: s.Selector) ![]const u8 {
        return self.fmt(".{{ .field = {}, .shift = {}, .bits = {}, .signed = {} }}", .{ selected.field, selected.shift, selected.bits, selected.signed });
    }

    fn scanCount(self: *Emitter, count: s.Count) ![]const u8 {
        return switch (count) {
            .fixed => |n| self.fmt(".{{ .fixed = {} }}", .{n}),
            .wire => |codec| self.fmt(".{{ .read = count_{s} }}", .{codec}),
            .field => |selected| self.fmt(".{{ .field = {s} }}", .{try self.scanSelector(selected)}),
            .sentinel => |n| self.fmt(".{{ .sentinel = {} }}", .{n}),
            .high_bit => self.fmt(".high_bit", .{}),
        };
    }

    fn envelope(self: *Emitter, scope: s.Scope) !void {
        const packet = self.graph.nodes.items[try self.graph.resolve(scope.types.get("packet") orelse return)];
        if (packet.kind != .container or packet.fields.len != 2) return error.InvalidPacketEnvelope;

        const mapper = self.graph.nodes.items[try self.graph.resolve(packet.fields[0].node)];
        const choice = self.graph.nodes.items[try self.graph.resolve(packet.fields[1].node)];
        try self.out.writeAll("pub const PacketName = enum {\n");

        for (mapper.mappings) |mapping| try self.out.print("@\"{s}\",\n", .{mapping.name});
        try self.out.writeAll(
            \\};
            \\pub const Header = struct { id: i32, body: []const u8 };
            \\pub fn readHeader(bytes: []const u8) c.Error!Header { const id, const body = try wire.read_varint(bytes);
            \\return .{ .id = id, .body = body };
            \\}
            \\pub fn packetId(comptime name: PacketName) i32 { return switch (name) {
            \\
        );

        for (mapper.mappings) |mapping| try self.out.print(".@\"{s}\" => {},\n", .{ mapping.name, mapping.value });
        try self.out.writeAll(
            \\};
            \\}
            \\pub fn PacketBody(comptime name: PacketName) type { return switch (name) {
            \\
        );

        for (choice.branches) |branch| try self.out.print(".@\"{s}\" => Readers.read_{},\n", .{ branch.name, try self.graph.resolve(branch.node) });
        try self.out.writeAll(
            \\};
            \\}
            \\pub fn readBody(comptime name: PacketName, header: Header) c.Error!PacketBody(name) { if (header.id != packetId(name)) return error.UnexpectedPacketId;
            \\return .{ ._cursor = .{ .buffer = header.body, .rest = header.body, .protocol_number = protocol_number } };
            \\}
            \\pub fn write(bytes: []u8) PacketWriter { return .{ ._cursor = .{ .buffer = bytes, .rest = bytes, .protocol_number = protocol_number } };
            \\}
            \\pub const PacketWriter = struct { _cursor: c.State(.write),
            \\
        );

        for (choice.branches) |branch| try self.out.print(
            \\pub fn @"{s}"(self: @This()) c.Error!Writers.write_{} {{ var _state = self._cursor;
            \\_state.rest = try wire.write_varint(_state.rest, packetId(.@"{s}"));
            \\return .{{ ._cursor = _state }};
            \\}}
            \\
        , .{ branch.name, try self.graph.resolve(branch.node), branch.name });
        try self.out.writeAll("};\n");
    }

    fn typeName(self: *Emitter, mode: []const u8, id: s.Id, step: usize) ![]const u8 {
        if (self.restricted) |restricted| if (id == restricted.root and std.mem.eql(u8, mode, "write")) {
            return self.fmt("write_case_{}_{}_{}_{}", .{ id, restricted.field, restricted.branch, step });
        };
        return if (step == 0) self.fmt("{s}_{}", .{ mode, id }) else self.fmt("{s}_{}_{}", .{ mode, id, step });
    }

    fn restrictable(self: *Emitter, root: s.Id, field: usize) !?s.Node {
        const node = self.graph.nodes.items[root];
        if (node.kind != .container or node.name.len == 0) return null;
        const choice = self.graph.nodes.items[try self.graph.resolve(node.fields[field].node)];
        if (choice.kind != .choice or choice.selector.field == s.none) return null;
        const selector = self.graph.bindings.items[choice.selector.field];
        if (selector.owner != root or selector.field >= field or choice.selector.shift != 0 or choice.selector.bits != 64) return null;
        const tag = self.graph.nodes.items[try self.graph.resolve(node.fields[selector.field].node)];
        if (tag.kind != .scalar or !numeric(tag.codec) or tag.members.len != 0) return null;
        return choice;
    }

    fn tagKey(self: *Emitter, node: s.Node, field: []const u8, branch: []const u8) !u64 {
        const key = try self.fmt("{s}/{s}/{s}/{s}", .{ self.graph.scopes.items[node.scope].name, node.name, field, branch });
        return std.hash.Wyhash.hash(0, key);
    }

    fn tagTable(self: *Emitter) !void {
        const Tag = struct {
            key: u64,
            value: i128,
            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return a.key < b.key;
            }
        };
        var tags: std.ArrayList(Tag) = .empty;
        defer tags.deinit(self.allocator);
        for (self.graph.nodes.items, 0..) |node, id| {
            if (node.name.len == 0 or node.kind != .container) continue;
            for (node.fields, 0..) |field, index| {
                const choice = (try self.restrictable(@intCast(id), index)) orelse continue;
                for (choice.branches) |branch| try tags.append(self.allocator, .{ .key = try self.tagKey(node, field.name, branch.name), .value = branch.value });
            }
        }
        std.mem.sort(Tag, tags.items, {}, Tag.lessThan);
        try self.out.writeAll("pub const case_tags = &[_]c.layout.Tag{\n");
        for (tags.items, 0..) |tag, index| {
            if (index != 0 and tags.items[index - 1].key == tag.key) return error.DuplicateCaseTag;
            try self.out.print(".{{ .key = {}, .value = {} }},\n", .{ tag.key, tag.value });
        }
        try self.out.writeAll("};\n");
    }

    fn referenceType(self: *Emitter, mode: []const u8, id: s.Id) ![]const u8 {
        const name = try self.fmt("{s}_{}", .{ mode, id });
        if (std.mem.eql(u8, mode, "write") and try self.isDestination(id))
            return self.fmt("c.Destination(\"{s}\")", .{try self.schemaName(id)});
        return name;
    }

    fn isDestination(self: *Emitter, id: s.Id) !bool {
        const node = self.graph.nodes.items[id];
        return node.name.len != 0 and node.root == id and !node.native and
            node.kind != .scalar and node.kind != .alias and node.kind != .constructor and
            !try self.requiresParentContext(id);
    }

    fn schemaName(self: *Emitter, id: s.Id) ![]const u8 {
        const node = self.graph.nodes.items[id];
        if (node.name.len == 0 or node.scope == 0) return node.name;
        return self.fmt("{s}.{s}", .{ self.graph.scopes.items[node.scope].name, node.name });
    }

    fn layoutTable(self: *Emitter) !void {
        try self.out.writeAll("const layout_nodes = [_]c.layout.Node{\n");
        var shape: std.Io.Writer.Allocating = .init(self.allocator);
        defer shape.deinit();
        for (self.graph.nodes.items, 0..) |node, id| {
            shape.clearRetainingCapacity();
            try self.layoutNode(&shape.writer, node);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(shape.written(), &hash, .{});
            try self.out.print(".{{ .name = \"{s}\", .shape = .{{", .{try self.schemaName(@intCast(id))});
            for (hash) |byte| try self.out.print("{},", .{byte});
            try self.out.print("}}, .destination = {},", .{try self.isDestination(@intCast(id))});
            if (node.kind == .choice) {
                shape.clearRetainingCapacity();
                try self.layoutSelector(&shape.writer, node.selector);
                std.crypto.hash.sha2.Sha256.hash(shape.written(), &hash, .{});
                try self.out.writeAll(".choice = .{ .shape = .{");
                for (hash) |byte| try self.out.print("{},", .{byte});
                try self.out.writeAll("}, .branches = &.{");
                for (node.branches) |branch| try self.out.print(".{{ .name = \"{s}\", .node = {} }},", .{ branch.name, try self.graph.resolve(branch.node) });
                try self.out.writeAll("} },");
            }
            if ((node.name.len != 0 or self.payloads[id]) and node.kind != .constructor and node.kind != .alias) {
                try self.out.writeAll(".fingerprint = .{");
                for (try self.layoutFingerprint(@intCast(id))) |byte| try self.out.print("{},", .{byte});
                try self.out.writeAll("},");
            }
            try self.out.writeAll(".children = &.{");
            for (node.fields) |field| {
                if (field.node != s.none) try self.out.print("{},", .{try self.graph.resolve(field.node)});
            }
            for (node.branches) |branch| try self.out.print("{},", .{try self.graph.resolve(branch.node)});
            if (node.child != s.none) try self.out.print("{},", .{try self.graph.resolve(node.child)});
            if (node.fallback != s.none) try self.out.print("{},", .{try self.graph.resolve(node.fallback)});
            try self.out.writeAll("} },\n");
        }
        try self.out.writeAll("};\n");
    }

    fn requiresParentContext(self: *Emitter, root: s.Id) !bool {
        var pending: std.ArrayList(s.Id) = .empty;
        defer pending.deinit(self.allocator);
        const visited = try self.allocator.alloc(s.Id, self.graph.nodes.items.len);
        defer self.allocator.free(visited);
        @memset(visited, s.none);
        try self.layoutReference(&pending, visited, root);
        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const node = self.graph.nodes.items[pending.items[index]];
            for ([_]s.Selector{ node.selector, if (node.count == .field) node.count.field else .{} }) |selector| {
                if (selector.field == s.none) continue;
                const owner = self.graph.bindings.items[selector.field].owner;
                var parent = self.graph.nodes.items[root].parent;
                while (parent != s.none) : (parent = self.graph.nodes.items[parent].parent) {
                    if (owner == parent) return true;
                }
            }
            for (node.fields) |field| try self.layoutReference(&pending, visited, field.node);
            for (node.branches) |branch| try self.layoutReference(&pending, visited, branch.node);
            try self.layoutReference(&pending, visited, node.child);
            try self.layoutReference(&pending, visited, node.fallback);
        }
        return false;
    }

    fn layoutFingerprint(self: *Emitter, root: s.Id) ![32]u8 {
        if (self.fingerprints[root]) |fingerprint| return fingerprint;
        const fingerprint = try self.computeFingerprint(root);
        self.fingerprints[root] = fingerprint;
        return fingerprint;
    }

    fn computeFingerprint(self: *Emitter, root: s.Id) ![32]u8 {
        var layout: std.Io.Writer.Allocating = .init(self.allocator);
        defer layout.deinit();
        var pending: std.ArrayList(s.Id) = .empty;
        defer pending.deinit(self.allocator);
        const visited = try self.allocator.alloc(s.Id, self.graph.nodes.items.len);
        defer self.allocator.free(visited);
        @memset(visited, s.none);
        visited[root] = 0;
        try pending.append(self.allocator, root);
        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const node = self.graph.nodes.items[pending.items[index]];
            for (node.fields) |field| try self.layoutReference(&pending, visited, field.node);
            for (node.branches) |branch| try self.layoutReference(&pending, visited, branch.node);
            try self.layoutReference(&pending, visited, node.child);
            try self.layoutReference(&pending, visited, node.fallback);
        }
        const nodes = try pending.toOwnedSlice(self.allocator);
        defer self.allocator.free(nodes);
        const signatures = try self.allocator.alloc([32]u8, nodes.len);
        defer self.allocator.free(signatures);
        const classes = try self.allocator.alloc(s.Id, nodes.len);
        defer self.allocator.free(classes);
        @memset(classes, 0);
        const order = try self.allocator.alloc(s.Id, nodes.len);
        defer self.allocator.free(order);
        var previous_count: usize = 0;
        // Sharing and aliases are not wire differences. Refine equivalent nodes
        // before serializing the graph. Recursive formats stay bounded too.
        while (true) {
            for (nodes, 0..) |id, local| {
                layout.clearRetainingCapacity();
                const node = self.graph.nodes.items[id];
                try self.layoutNode(&layout.writer, node);
                try layout.writer.print("|{}|", .{classes[local]});
                for (node.fields) |field| try layout.writer.print("{}:", .{if (field.node == s.none) s.none else classes[visited[try self.graph.resolve(field.node)]]});
                for (node.branches) |branch| try layout.writer.print("{}:", .{classes[visited[try self.graph.resolve(branch.node)]]});
                for ([_]s.Id{ node.child, node.fallback }) |child|
                    try layout.writer.print("{}:", .{if (child == s.none) s.none else classes[visited[try self.graph.resolve(child)]]});
                std.crypto.hash.sha2.Sha256.hash(layout.written(), &signatures[local], .{});
                order[local] = @intCast(local);
            }
            std.mem.sort(s.Id, order, signatures, struct {
                fn less(hashes: [][32]u8, a: s.Id, b: s.Id) bool {
                    return std.mem.order(u8, &hashes[a], &hashes[b]) == .lt;
                }
            }.less);
            var count: usize = 1;
            classes[order[0]] = 0;
            for (order[1..], order[0 .. order.len - 1]) |current, previous| {
                if (!std.mem.eql(u8, &signatures[current], &signatures[previous])) count += 1;
                classes[current] = @intCast(count - 1);
            }
            std.debug.assert(count >= previous_count and count <= nodes.len);
            if (count == previous_count) break;
            previous_count = count;
        }
        const canonical = try self.allocator.alloc(s.Id, nodes.len);
        defer self.allocator.free(canonical);
        @memset(canonical, s.none);
        canonical[classes[0]] = 0;
        try pending.append(self.allocator, root);
        layout.clearRetainingCapacity();
        index = 0;
        var children: std.ArrayList(s.Id) = .empty;
        defer children.deinit(self.allocator);
        while (index < pending.items.len) : (index += 1) {
            const node = self.graph.nodes.items[pending.items[index]];
            try self.layoutNode(&layout.writer, node);
            children.clearRetainingCapacity();
            for (node.fields) |field| try children.append(self.allocator, field.node);
            for (node.branches) |branch| try children.append(self.allocator, branch.node);
            try children.appendSlice(self.allocator, &.{ node.child, node.fallback });
            for (children.items) |child| {
                if (child == s.none) {
                    try std.json.Stringify.value(s.none, .{}, &layout.writer);
                    continue;
                }
                const id = try self.graph.resolve(child);
                const class = classes[visited[id]];
                if (canonical[class] == s.none) {
                    canonical[class] = @intCast(pending.items.len);
                    try pending.append(self.allocator, id);
                }
                try std.json.Stringify.value(canonical[class], .{}, &layout.writer);
            }
        }
        var fingerprint: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(layout.written(), &fingerprint, .{});
        return fingerprint;
    }

    fn layoutNode(self: *Emitter, out: *std.Io.Writer, node: s.Node) !void {
        try std.json.Stringify.value(.{ node.kind, node.codec, node.members, node.fields.len, node.branches.len, node.child != s.none, node.fallback != s.none }, .{}, out);
        for (node.fields) |field| {
            try std.json.Stringify.value(.{ field.name, field.binding != s.none }, .{}, out);
        }
        for (node.branches) |branch| {
            try std.json.Stringify.value(.{ branch.name, branch.value }, .{}, out);
        }
        try self.layoutSelector(out, node.selector);
        switch (node.count) {
            .field => |selector| {
                try out.writeAll("field");
                try self.layoutSelector(out, selector);
            },
            else => try std.json.Stringify.value(node.count, .{}, out),
        }
    }

    fn layoutReference(self: *Emitter, pending: *std.ArrayList(s.Id), visited: []s.Id, raw: s.Id) !void {
        if (raw == s.none) return;
        const id = try self.graph.resolve(raw);
        if (visited[id] == s.none) {
            visited[id] = @intCast(pending.items.len);
            try pending.append(self.allocator, id);
        }
    }

    fn layoutSelector(self: *Emitter, out: *std.Io.Writer, selector: s.Selector) !void {
        try std.json.Stringify.value(.{ selector.field != s.none, selector.shift, selector.bits, selector.signed }, .{}, out);
        if (selector.field == s.none) return;
        const binding = self.graph.bindings.items[selector.field];
        try std.json.Stringify.value(binding.field, .{}, out);
        var owner = binding.owner;
        while (self.graph.nodes.items[owner].parent != s.none) {
            const node = self.graph.nodes.items[owner];
            try std.json.Stringify.value(node.position, .{}, out);
            owner = node.parent;
        }
        try out.writeByte('\n');
    }

    fn gate(self: *Emitter, entry_name: []const u8, next: []const u8, mode: []const u8, capture: s.Id) ![]const u8 {
        return self.fmt("c.Child({s}, {s}, .{s}, \"{s}\")", .{ entry_name, next, mode, if (capture == s.none) "" else try self.fmt("v_{}", .{capture}) });
    }

    fn sequenceType(self: *Emitter, child: []const u8, next: []const u8, mode: []const u8, count: s.Count) ![]const u8 {
        return self.fmt("c.Sequence({s}, {s}, .{s}, {s})", .{ child, next, mode, switch (count) {
            .sentinel => |n| try self.fmt(".{{ .sentinel = {} }}", .{n}),
            .high_bit => ".high_bit",
            else => ".counted",
        } });
    }

    fn gateInit(self: *Emitter, child: []const u8, next: []const u8) ![]const u8 {
        return self.fmt(".{{ .next_value = .{{ ._cursor = _state, ._context = c.context({s}.Context, self._context) }}, .child_context = c.context({s}.Context, self._context) }}", .{ next, child });
    }

    fn selectorExpr(self: *Emitter, selected: s.Selector) ![]const u8 {
        return self.fmt("c.select(self._context.v_{}, {}, {}, {})", .{ selected.field, selected.shift, selected.bits, selected.signed });
    }

    fn fmt(self: *Emitter, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, format, args);
    }

    fn memberType(self: *Emitter, member: s.Member) ![]const u8 {
        return if (member.bits == 1 and !member.signed) "bool" else self.fmt("{s}{}", .{ if (member.signed) "i" else "u", if (member.bits <= 8) @as(u8, 8) else if (member.bits <= 16) @as(u8, 16) else if (member.bits <= 32) @as(u8, 32) else @as(u8, 64) });
    }
};

fn valueType(allocator: std.mem.Allocator, codec: []const u8) ![]const u8 {
    if (std.mem.eql(u8, codec, "varint")) return "i32";
    if (std.mem.eql(u8, codec, "varlong")) return "i64";
    if (std.mem.eql(u8, codec, "UUID")) return "u128";
    if (numeric(codec) or std.mem.eql(u8, codec, "bool") or std.mem.eql(u8, codec, "void") or std.mem.eql(u8, codec, "f32") or std.mem.eql(u8, codec, "f64"))
        return codec;
    return std.fmt.allocPrint(allocator, "wire.{s}", .{codec});
}

fn numeric(codec: []const u8) bool {
    for ([_][]const u8{ "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "varint", "varlong" }) |name|
        if (std.mem.eql(u8, name, codec)) return true;
    return false;
}
