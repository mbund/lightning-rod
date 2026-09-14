const std = @import("std");
const s = @import("schema.zig");

pub const Emitter = struct {
    graph: *const s.Graph,
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,

    pub fn run(self: *Emitter) !void {
        try self.out.writeAll(
            \\const std = @import("std");
            \\const wire = @import("protocol_support");
            \\const c = wire.cursor;
            \\const scanner = wire.scan;
            \\
        );

        for (self.graph.nodes.items, 0..) |node, id| {
            if (node.kind == .scalar) try self.scalar(@intCast(id), node);

            if (node.root == id) {
                try self.out.print("const Context_{} = struct {{\n", .{id});

                for (self.graph.bindings.items, 0..) |binding, index| {
                    if (self.graph.nodes.items[binding.owner].root == id) try self.out.print("v_{}: i128 = 0,\n", .{index});
                }

                try self.out.writeAll("};\n");
            }
        }

        try self.scanTable();

        for ([_][]const u8{ "read", "write" }) |mode| {
            for (self.graph.nodes.items, 0..) |node, id| {
                if (node.kind == .constructor or node.kind == .alias) continue;
                try self.cursor(@intCast(id), node, mode);
            }
        }

        for (self.graph.scopes.items, 0..) |scope, scope_index| {
            if (scope_index != 0) {
                const dot = std.mem.indexOfScalar(u8, scope.name, '.').?;

                if (scope_index % 2 == 1) try self.out.print("pub const {s} = struct {{\n", .{scope.name[0..dot]});
                try self.out.print("pub const {s} = struct {{\n", .{scope.name[dot + 1 ..]});
            }

            var names = scope.types.iterator();

            while (names.next()) |entry| {
                if (self.graph.nodes.items[entry.value_ptr.*].native) continue;

                const id = try self.graph.resolve(entry.value_ptr.*);
                if (self.graph.nodes.items[id].kind == .constructor) continue;
                try self.out.print(
                    \\pub const @"{s}" = struct {{
                    \\    pub const Reader = read_{};
                    \\    pub const Writer = write_{};
                    \\    pub fn read(bytes: []const u8) Reader {{
                    \\        return .{{ ._cursor = .init(bytes) }};
                    \\    }}
                    \\    pub fn write(bytes: []u8) Writer {{
                    \\        return .{{ ._cursor = .init(bytes) }};
                    \\    }}
                    \\}};
                    \\
                , .{ entry.key_ptr.*, id, id });
            }

            if (scope_index != 0) {
                try self.envelope(scope);
                try self.out.writeAll("};\n");

                if (scope_index % 2 == 0) try self.out.writeAll("};\n");
            }
        }
    }

    fn cursor(self: *Emitter, id: s.Id, node: s.Node, mode: []const u8) !void {
        const fields = if (node.kind == .container) node.fields else &.{};
        const steps = @max(1, fields.len);
        const end = try self.fmt("{s}_{}.Done", .{ mode, id });

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

            if (step == 0) try self.out.print("pub const Done = c.End(@This(), .{s});\n", .{mode});
            if (step == 0 and std.mem.eql(u8, mode, "read")) {
                try self.out.writeAll(
                    \\pub fn scan(self: @This()) c.Error!Done {
                    \\const variables = [_]scanner.Variable{
                    \\
                );

                for (self.graph.bindings.items, 0..) |binding, binding_id| if (self.graph.nodes.items[binding.owner].root == node.root) {
                    try self.out.print(".{{ .id = {}, .value = self._context.v_{} }},\n", .{ binding_id, binding_id });
                };

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
                        const child = try self.typeName(mode, try self.graph.resolve(node.child), 0);
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
                        try self.emitEntry(mode, branch.node, try self.fmt("case_{s}", .{branch.name}), end, s.none, .{ .code = try self.fmt("if ({s} != {}) return error.InvalidTag;", .{ selector, branch.value }) });
                    var checks: std.Io.Writer.Allocating = .init(self.allocator);

                    for (node.branches) |branch| try checks.writer.print("if ({s} == {}) return error.InvalidTag;\n", .{ selector, branch.value });

                    if (node.fallback != s.none) try self.emitEntry(mode, node.fallback, "case_default", end, s.none, .{ .code = checks.written() });
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
                            try self.out.print("@\"{s}\": {s},\n", .{ branch.name, try self.gate(try self.typeName(mode, try self.graph.resolve(branch.node), 0), end, mode, s.none) });
                        const fallback = if (node.fallback == s.none) "" else try self.typeName(mode, try self.graph.resolve(node.fallback), 0);

                        if (node.fallback != s.none) try self.out.print("default: {s},\n", .{try self.gate(fallback, end, mode, s.none)});
                        try self.out.writeAll("} { const _state = self._cursor;\n");

                        for (node.branches) |branch|
                            try self.out.print("if ({s} == {}) return .{{ .@\"{s}\" = {s} }};\n", .{ selector, branch.value, branch.name, try self.gateInit(try self.typeName(mode, try self.graph.resolve(branch.node), 0), end) });

                        if (node.fallback != s.none) try self.out.print("return .{{ .default = {s} }}; }}\n", .{try self.gateInit(fallback, end)}) else try self.out.writeAll("return error.InvalidTag; }\n");
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

    fn emitEntry(self: *Emitter, mode: []const u8, original: s.Id, method: []const u8, next: []const u8, capture: s.Id, prefix: struct {
        code: []const u8 = "",
        writes: bool = false,
    }) !void {
        const id = try self.graph.resolve(original);
        const node = self.graph.nodes.items[id];
        const reading = std.mem.eql(u8, mode, "read");
        const scalar_node = node.kind == .scalar;
        const sequence = node.kind == .array;
        const counted = sequence and (node.count == .wire or node.count == .sentinel or node.count == .high_bit);
        const child = try self.typeName(mode, if (sequence) try self.graph.resolve(node.child) else id, 0);
        const result = if (scalar_node) if (reading) try self.fmt("struct {{ Scalar_{}.Value, {s} }}", .{ id, next }) else next else if (sequence) try self.sequenceType(child, next, mode, node.count) else try self.gate(child, next, mode, capture);
        const argument = if (reading) "" else if (scalar_node and !std.mem.eql(u8, node.codec, "void")) try self.fmt(", field_value: Scalar_{}.Value", .{id}) else if (counted) ", length: usize" else "";
        try self.out.print("pub fn @\"{s}\"(self: @This(){s}) c.Error!{s} {{\n", .{ method, argument, result });
        const mutable = scalar_node or prefix.writes or (sequence and node.count == .wire);
        try self.out.print(
            \\{s} _state = self._cursor;
            \\{s}
            \\
        , .{ if (mutable) "var" else "const", prefix.code });

        if (scalar_node) {
            const length = if (node.count == .field) try self.fmt("try wire.count_to_usize({s})", .{try self.selectorExpr(node.count.field)}) else "0";

            if (reading) try self.out.print("const field_value, const rest, const captured = try Scalar_{}.read(_state.rest, {s}, _state.first_mask);\n", .{ id, length }) else try self.out.print("const rest, const captured = try Scalar_{}.write(_state.rest, {s}, {s});\n", .{ id, if (std.mem.eql(u8, node.codec, "void")) "{}" else "field_value", length });
            try self.out.writeAll("_state.rest = rest; _state.value = captured; _state.first_mask = 255;\n");

            if (capture != s.none) {
                try self.out.print("var next_context = c.context({s}.Context, self._context); next_context.v_{} = captured;\n", .{ next, capture });
            } else try self.out.print("const next_context = c.context({s}.Context, self._context);\n", .{next});
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
                    if (reading) try self.out.writeAll("const length = wire.maximum_sequence_elements;\n") else try self.out.writeAll("_ = try c.count(length);\n");
                    if (!reading and node.count == .high_bit) try self.out.writeAll("if (length == 0) return error.MissingItems;\n");
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
        const child = try self.typeName(mode, try self.graph.resolve(second.node), 0);

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
            const base = if (set) try self.typeName(mode, try self.graph.resolve(first.node), 0) else "";
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

        for (choice.branches) |branch| try self.out.print(".@\"{s}\" => read_{},\n", .{ branch.name, try self.graph.resolve(branch.node) });
        try self.out.writeAll(
            \\};
            \\}
            \\pub fn readBody(comptime name: PacketName, header: Header) c.Error!PacketBody(name) { if (header.id != packetId(name)) return error.UnexpectedPacketId;
            \\return .{ ._cursor = .init(header.body) };
            \\}
            \\pub fn write(bytes: []u8) PacketWriter { return .{ ._cursor = .init(bytes) };
            \\}
            \\pub const PacketWriter = struct { _cursor: c.State(.write),
            \\
        );

        for (choice.branches) |branch| try self.out.print(
            \\pub fn @"{s}"(self: @This()) c.Error!write_{} {{ var _state = self._cursor;
            \\_state.rest = try wire.write_varint(_state.rest, packetId(.@"{s}"));
            \\return .{{ ._cursor = _state }};
            \\}}
            \\
        , .{ branch.name, try self.graph.resolve(branch.node), branch.name });
        try self.out.writeAll("};\n");
    }

    fn typeName(self: *Emitter, mode: []const u8, id: s.Id, step: usize) ![]const u8 {
        return if (step == 0) self.fmt("{s}_{}", .{ mode, id }) else self.fmt("{s}_{}_{}", .{ mode, id, step });
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
