const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const json = try readJson(
        allocator,
        "/var/home/josh/src/lightning-rod/minecraft-data/data/pc/1.20/protocol.json",
    );
    defer json.deinit();

    const protocol = try Protocol.fromJson(allocator, json.value);
    const buffer = try allocator.alloc(u8, 4096);
    var stdout = std.fs.File.stdout().writer(buffer);
    var writer = IndentedWriter{ .writer = &stdout.interface };
    try protocol.codegen(allocator, &writer);
    try stdout.interface.flush();
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
        try writer.println("const protocol_support = @import(\"protocol_support.zig\");\n", .{});
        try self.types.codegen(allocator, writer, .{ .outer = &self.types, .inner = null });
        try writer.println("", .{});
        try self.handshaking.codegen(allocator, writer, "handshaking", &self.types);
        // try self.status.codegen(allocator, writer, "status", &self.types, 0);
        // try self.login.codegen(allocator, writer, "login", &self.types, 0);
        // try self.play.codegen(allocator, writer, "play", &self.types, 0);
        try writer.println("", .{});
    }
};

const Types = struct {
    types: std.StringHashMap(Type),

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !Types {
        const object = try expectObject(json);
        var types = std.StringHashMap(Type).init(allocator);

        var it = object.iterator();
        while (it.next()) |entry| {
            try types.put(entry.key_ptr.*, try Type.fromJson(allocator, entry.key_ptr.*, entry.value_ptr.*));
        }

        return Types{
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
        }
    }
};

const State = struct {
    toServer: Types,
    // toClient: Types,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !State {
        return .{
            .toServer = try Types.fromJson(allocator, try expectGet(try expectObject(try expectGet(try expectObject(json), "toServer")), "types")),
            // .toClient = try Types.fromJson(allocator, try expectGet(try expectObject(try expectGet(try expectObject(json), "toClient")), "types")),
        };
    }

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *IndentedWriter, name: []const u8, outer: *const Types) !void {
        try writer.println("pub const {s} = struct {{", .{name});
        writer.indent();

        try writer.println("pub const toServer = struct {{", .{});
        writer.indent();
        try self.toServer.codegen(allocator, writer, .{ .outer = outer, .inner = &self.toServer });
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
            .registryEntryHolder => "protocol_support.registryEntryHolder",
            .registryEntryHolderSet => "protocol_support.registryEntryHolderSet",
            .fake => error.ReferencedFakeNativeType,
        };
    }
};

const Field = struct {
    name: []const u8,
    type: Type,
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

const Type = union(enum) {
    reference: []const u8,
    todo,
    native: NativeType,
    container: struct { fields: []Field },
    bitfield: struct { fields: []BitfieldField },
    array: struct { count: ArrayCount, elementType: *Type },
    pstring: struct { countType: NativeType },
    switch_: struct { compareTo: []const u8, fields: []Field, default: *Type },
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
            .switch_ => |switch_| {
                const compareTo = try resolveReference(switch_.compareTo, parentContainer);
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
            else => return error.Todo1,
        }
    }
};

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
                    return error.Todo2;
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
};

const ResolvedVariant = struct {
    value: []const u8,
    type: *ResolvedType,
};

const ResolvedType = union(enum) {
    todo,
    native: NativeType,
    container: ResolvedContainer,
    pstring: struct { countType: NativeType },
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
                    return error.Todo3;
                }
                return container.cursor(cursors, 0);
            },
            .pstring => |pstring| {
                const result = try cursors.allocateCursor();
                result.kind = .{ .simple = .{ .readType = .{ .pstring = pstring.countType }, .next = null } };
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
                                @panic("unreachable");
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
                        return error.Todo5;
                    },
                }
            },
            else => {
                return error.Todo4;
            },
        }
    }
};

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

                pub fn codegenType(self: @This()) ![]const u8 {
                    return switch (self) {
                        .native => |native| try native.codegenType(),
                        .pstring => |_| "[]const u8",
                    };
                }
            },
            next: ?*Cursor,
        },
        variants: struct {
            readType: NativeType,
            variants: []CursorVariant,
            default: *Cursor,
        },
    },
    fieldName: []const u8,
    visited: bool = false,

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
                try writer.println("pub fn {s}(self: @This()) !struct {{ {s}, {s} }} {{", .{ self.fieldName, try simple.readType.codegenType(), cursorName(simple.next) });
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
            .variants => |variants| {
                try writer.println("pub fn {s}(self: @This()) !union(enum) {{", .{self.fieldName});
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
        }
    }

    pub fn updateNext(self: *Cursor, next: *Cursor) !void {
        switch (self.kind) {
            .simple => |_| {
                self.kind.simple.next = next;
            },
            else => return error.UpdateNextOnNonSimple,
        }
    }
};

fn cursorName(cursor: ?*Cursor) []const u8 {
    return if (cursor) |c| c.name else "protocol_support.FinalCursor";
}

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
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(std.json.Value) {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(u64));
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
        };

        for (keywords) |keyword| {
            if (std.mem.eql(u8, keyword, s)) {
                return true;
            }
        }
        return false;
    }

    pub fn format(
        self: @This(),
        writer: anytype,
    ) !void {
        if (@This().isKeyword(self.input)) {
            try writer.print("@\"{s}\"", .{self.input});
        } else {
            try writer.writeAll(self.input);
        }
    }
};

fn printIndent(writer: *std.io.Writer, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.print("    ", .{});
    }
}

const IndentedWriter = struct {
    writer: *std.io.Writer,
    level: usize = 0,

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
};
