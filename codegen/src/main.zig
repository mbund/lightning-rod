const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const json = try readJson(
        allocator,
        "/var/home/josh/src/lightning-rod/minecraft-data/data/pc/1.21.8/protocol.json",
    );
    defer json.deinit();

    var ns_stack = try std.ArrayList(Namespace).initCapacity(allocator, 0);
    try ns_stack.append(allocator, Namespace.init(allocator));
    defer ns_stack.deinit(allocator);

    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var stdout_writer = std.fs.File.stdout().writer(buffer);
    try codegenNamespace(allocator, json.value, &ns_stack, &stdout_writer.interface);
    ns_stack.items[0].deinit();

    try stdout_writer.interface.flush();
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
    types: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) Namespace {
        return .{ .types = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *Namespace) void {
        self.types.deinit();
    }
};

pub fn namespaceContains(ns_stack: []Namespace, key: []const u8) bool {
    var i: usize = ns_stack.len;
    while (i > 0) {
        i -= 1;
        if (ns_stack[i].types.contains(key)) {
            return true;
        }
    }
    return false;
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
                            try codegenType(allocator, type_entry, ns_stack, writer);
                        }
                    }
                } else {
                    try indent(writer, ns_stack.items.len - 1);
                    try writer.print("pub const @\"{s}\" = struct {{\n", .{entry.key_ptr.*});
                    try ns_stack.append(allocator, Namespace.init(allocator));
                    try codegenNamespace(allocator, entry.value_ptr.*, ns_stack, writer);
                    var ns = ns_stack.pop().?;
                    ns.deinit();
                    try indent(writer, ns_stack.items.len - 1);
                    try writer.print("}};\n\n", .{});
                }
            }
        },
        else => {
            return error.ExpectedObject;
        },
    }
}

fn codegenType(
    allocator: std.mem.Allocator,
    type_entry: std.json.ObjectMap.Entry,
    ns_stack: *std.ArrayList(Namespace),
    writer: *std.io.Writer,
) !void {
    _ = allocator;
    try indent(writer, ns_stack.items.len - 1);
    switch (type_entry.value_ptr.*) {
        .string => |str| {
            if (std.mem.eql(u8, str, "native")) {
                try writer.print("pub const @\"{s}\" = \"native\";\n", .{type_entry.key_ptr.*});
            } else if (namespaceContains(ns_stack.items, str)) {
                try writer.print("pub const @\"{s}\" = \"good {s}\";\n", .{ type_entry.key_ptr.*, str });
            } else {
                try writer.print("pub const @\"{s}\" = \"bad {s}\";\n", .{ type_entry.key_ptr.*, str });
            }
        },
        else => {
            try writer.print("pub const @\"{s}\" = \"<object>\";\n", .{type_entry.key_ptr.*});
        },
    }
}

fn indent(writer: *std.io.Writer, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.print("    ", .{});
    }
}
