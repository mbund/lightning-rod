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
    try protocol.codegen(allocator, &stdout.interface);
    try stdout.interface.flush();
}

const Protocol = struct {
    types: Types,
    // handshaking: State,
    // status: State,
    // login: State,
    // play: State,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !Protocol {
        const object = try expectObject(json);
        const types = try Types.fromJson(allocator, try expectGet(object, "types"));

        return Protocol{
            .types = types,
        };
    }

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *std.io.Writer) !void {
        try writer.print("const std = @import(\"std\");\n", .{});
        try writer.print("const protocol_support = @import(\"protocol_support.zig\");\n\n", .{});
        try self.types.codegen(allocator, writer, 0, .{ .outer = &self.types, .inner = null });
        try writer.print("\n", .{});
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

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *std.io.Writer, indent: usize, scope: Scope) !void {
        var it = self.types.iterator();
        while (it.next()) |entry| {
            try entry.value_ptr.codegenDefinition(allocator, entry.key_ptr.*, writer, indent, scope);
        }
    }
};

const State = struct {
    ToServer: Types,
    ToClient: Types,
};

const Scope = struct {
    outer: *const Types,
    inner: ?*const Types,
};

const NativeType = enum {
    varint,
    varlong,
    optvarint,
    pstring,
    buffer,
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
        if (std.mem.eql(u8, str, "optvarint")) {
            return .optvarint;
        }
        if (std.mem.eql(u8, str, "pstring")) {
            return .pstring;
        }
        if (std.mem.eql(u8, str, "buffer")) {
            return .buffer;
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
        if (std.mem.eql(u8, str, "bitfield")) {
            return .bitfield;
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
            .optvarint => "protocol_support.optvarint",
            .pstring => "protocol_support.pstring",
            .buffer => "protocol_support.buffer",
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

const Type = union(enum) {
    reference: []const u8,
    varint,
    todo,
    native: NativeType,
    container: struct { name: []const u8, fields: []Field },

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
                return .{ .container = .{ .name = key, .fields = fields } };
            }
        }

        return .todo;
    }

    pub fn codegenDefinition(self: *const @This(), allocator: std.mem.Allocator, name: []const u8, writer: *std.io.Writer, indent: usize, scope: Scope) !void {
        switch (self.*) {
            .container, .todo => {
                try printIndent(writer, indent);
                try writer.print("pub const {f} = ", .{idfmt(name)});
                try self.codegenType(allocator, writer, indent, scope);
                try writer.print(";\n\n", .{});
            },
            else => {},
        }
    }

    pub fn codegenType(self: *const @This(), allocator: std.mem.Allocator, writer: *std.io.Writer, indent: usize, scope: Scope) !void {
        switch (self.*) {
            .reference => |reference| {
                if (scope.outer.types.get(reference)) |referenced| {
                    switch (referenced) {
                        .native => |native| try writer.print("{s}", .{try native.codegenType()}),
                        else => try writer.print("{s}", .{reference}),
                    }
                } else {
                    return error.UndefinedReference;
                }
            },
            .native => |_| {
                return error.UnexpectedNative;
            },
            .container => |container| {
                try writer.print("struct {{\n", .{});
                for (container.fields) |field| {
                    try printIndent(writer, indent + 1);
                    try writer.print("{f}: ", .{idfmt(field.name)});
                    try field.type.codegenType(allocator, writer, indent + 1, scope);
                    try writer.print(",\n", .{});
                }
                try writer.print("\n", .{});
                try printIndent(writer, indent + 1);
                try writer.print("pub fn read(self: *@This(), r: *protocol_support.Reader, allocator: std.mem.Allocator) !void {{\n", .{});
                try printIndent(writer, indent + 2);
                try writer.print("protocol_support.maybe_unused(allocator);\n", .{});
                try printIndent(writer, indent + 2);
                try self.codegenRead(allocator, writer, indent + 2, scope, "self", null);
                try writer.print("\n", .{});
                try printIndent(writer, indent + 1);
                try writer.print("}}\n", .{});
                try printIndent(writer, indent);
                try writer.print("}}", .{});
            },
            else => {
                try writer.print("protocol_support.Todo", .{});
            },
        }
    }

    pub fn codegenRead(
        self: *const @This(),
        allocator: std.mem.Allocator,
        writer: *std.io.Writer,
        indent: usize,
        scope: Scope,
        dest: []const u8,
        parent_dest: ?[]const u8,
    ) anyerror!void {
        _ = parent_dest;
        switch (self.*) {
            .reference => |reference| {
                if (scope.outer.types.get(reference)) |referenced| {
                    switch (referenced) {
                        .native => |native| {
                            try writer.print("try r.read_{s}(&{s});", .{ @tagName(native), dest });
                        },
                        .container => |_| {
                            try writer.print("try {s}.read(r, allocator);", .{dest});
                        },
                        else => |_| {
                            try writer.print("try protocol_support.todo(r, &{s});", .{dest});
                        },
                    }
                } else {
                    return error.UndefinedReference;
                }
            },
            .native => |_| {
                return error.UnexpectedNative;
            },
            .container => |container| {
                var dest_buf: [256]u8 = undefined;
                for (0.., container.fields) |i, field| {
                    if (i >= 1) {
                        try writer.print("\n", .{});
                        try printIndent(writer, indent);
                    }
                    const child_dest = try std.fmt.bufPrint(&dest_buf, "{s}.{s}", .{ dest, field.name });
                    try field.type.codegenRead(allocator, writer, indent, scope, child_dest, dest);
                }
            },
            else => {
                try writer.print("try protocol_support.todo(r, &{s});", .{dest});
            },
        }
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

fn printIndent(writer: *std.io.Writer, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.print("    ", .{});
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
