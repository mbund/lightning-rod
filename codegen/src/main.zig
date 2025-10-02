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
        try self.types.codegen(allocator, writer, 0);
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
            try types.put(entry.key_ptr.*, try Type.fromJson(allocator, entry.value_ptr.*));
        }

        return Types{
            .types = types,
        };
    }

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *std.io.Writer, indent: usize) !void {
        _ = allocator;
        var it = self.types.iterator();
        while (it.next()) |entry| {
            try printIndent(writer, indent);
            try writer.print("const {f} = struct {{}};\n", .{idfmt(entry.key_ptr.*)});
        }
    }
};

const State = struct {
    ToServer: Types,
    ToClient: Types,
};

const Type = union(enum) {
    reference: []u8,
    varint,
    todo,

    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !Type {
        _ = allocator;
        _ = json;
        return .todo;
    }

    pub fn codegen(self: *const @This(), allocator: std.mem.Allocator, writer: *std.io.Writer, indent: usize) !void {
        _ = self;
        _ = allocator;
        _ = writer;
        _ = indent;
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

fn expectGet(object: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return object.get(key) orelse {
        return error.MissingKey;
    };
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
