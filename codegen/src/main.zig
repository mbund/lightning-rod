const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const json = try readJson(
        allocator,
        "/var/home/josh/src/lightning-rod/minecraft-data/data/pc/1.20/protocol.json",
    );
    defer json.deinit();

    var ns_stack = try std.ArrayList(Namespace).initCapacity(allocator, 0);
    try ns_stack.append(allocator, Namespace.init(allocator, "codegen"));
    defer ns_stack.deinit(allocator);

    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var writer = std.fs.File.stdout().writer(buffer);

    try writer.interface.print("const codegen_support = @import(\"codegen_support.zig\");\n", .{});
    try writer.interface.print("const codegen = @This();\n", .{});

    try codegenNamespace(allocator, json.value, &ns_stack, &writer.interface);
    ns_stack.items[0].deinit();

    try writer.interface.flush();
}

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

const Namespace = struct {
    name: []const u8,
    types: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Namespace {
        return .{
            .name = name,
            .types = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Namespace) void {
        self.types.deinit();
    }
};

pub fn namespaceLookup(ns_stack: []Namespace, key: []const u8) !usize {
    var ns_index: usize = ns_stack.len;
    while (ns_index > 0) {
        ns_index -= 1;
        if (ns_stack[ns_index].types.contains(key)) {
            return ns_index;
        }
    }
    return error.UndefinedType;
}

fn codegenNamespace(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    ns_stack: *std.ArrayList(Namespace),
    writer: *std.io.Writer,
) !void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "types")) {
                    if (entry.value_ptr.* == .object) {
                        var t_it = entry.value_ptr.*.object.iterator();
                        while (t_it.next()) |type_entry| {
                            try ns_stack.items[ns_stack.items.len - 1].types.put(type_entry.key_ptr.*, void{});
                            try printIndent(writer, ns_stack.items.len - 1);
                            try writer.print("pub const {f} = ", .{idfmt(type_entry.key_ptr.*)});
                            try codegenType(allocator, type_entry.key_ptr.*, type_entry.value_ptr.*, ns_stack, writer, ns_stack.items.len - 1);
                            try writer.print(";\n", .{});
                        }
                    }
                } else {
                    try printIndent(writer, ns_stack.items.len - 1);
                    try writer.print("pub const {f} = struct {{\n", .{idfmt(entry.key_ptr.*)});
                    try ns_stack.append(allocator, Namespace.init(allocator, entry.key_ptr.*));
                    try codegenNamespace(allocator, entry.value_ptr.*, ns_stack, writer);
                    var ns = ns_stack.pop().?;
                    ns.deinit();
                    try printIndent(writer, ns_stack.items.len - 1);
                    try writer.print("}};\n", .{});
                }
            }
        },
        else => {
            return error.InvalidProtocol;
        },
    }
}

fn codegenType(
    allocator: std.mem.Allocator,
    name: []const u8,
    typ: std.json.Value,
    ns_stack: *std.ArrayList(Namespace),
    writer: *std.io.Writer,
    indent: usize,
) anyerror!void {
    switch (typ) {
        .string => |str| {
            if (std.mem.eql(u8, str, "native")) {
                try writer.print("codegen_support.{f}", .{idfmt(name)});
            } else {
                const ns_index = try namespaceLookup(ns_stack.items, str);
                for (0..ns_index + 1) |i| {
                    try writer.print("{f}.", .{idfmt(ns_stack.items[i].name)});
                }
                try writer.print("{f}", .{idfmt(str)});
            }
        },
        .array => |array| {
            if (array.items.len != 2) {
                return error.InvalidProtocol;
            }
            switch (array.items[0]) {
                .string => |constructor| {
                    if (std.mem.eql(u8, constructor, "container")) {
                        try codegenContainer(allocator, array.items[1], ns_stack, writer, indent);
                    } else {
                        try writer.print("\"<{s}>\"", .{constructor});
                    }
                },
                else => {
                    return error.InvalidProtocol;
                },
            }
        },
        else => {
            return error.InvalidProtocol;
        },
    }
}

fn codegenContainer(
    allocator: std.mem.Allocator,
    container: std.json.Value,
    ns_stack: *std.ArrayList(Namespace),
    writer: *std.io.Writer,
    indent: usize,
) anyerror!void {
    try writer.print("struct {{\n", .{});
    switch (container) {
        .array => |array| {
            for (array.items) |container_item| {
                switch (container_item) {
                    .object => |container_entry| {
                        const name = if (container_entry.contains("anon")) "anon" else blk: {
                            const name_entry = container_entry.get("name") orelse {
                                return error.InvalidProtocol;
                            };
                            switch (name_entry) {
                                .string => |name| break :blk name,
                                else => {
                                    return error.InvalidProtocol;
                                },
                            }
                        };
                        const typ = container_entry.get("type") orelse {
                            return error.InvalidProtocol;
                        };
                        try printIndent(writer, indent + 1);
                        try writer.print("{f}: ", .{idfmt(name)});
                        try codegenType(allocator, "", typ, ns_stack, writer, indent + 1);
                        try writer.print(",\n", .{});
                    },
                    else => {
                        return error.InvalidProtocol;
                    },
                }
            }
        },
        else => {
            return error.InvalidProtocol;
        },
    }
    try printIndent(writer, indent);
    try writer.print("}}", .{});
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
