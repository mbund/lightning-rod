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

    var stack = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer stack.deinit(allocator);

    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var stdout_writer = std.fs.File.stdout().writer(buffer);
    try codegenNamespace(allocator, json.value, &stack, &stdout_writer.interface);
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

fn codegenNamespace(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    ns_stack: *std.ArrayList([]const u8),
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
                            try codegenType(allocator, type_entry, ns_stack, writer);
                        }
                    }
                } else {
                    try indent(writer, ns_stack.items.len);
                    try writer.print("pub const @\"{s}\" = struct {{\n", .{entry.key_ptr.*});
                    try ns_stack.append(allocator, entry.key_ptr.*);
                    try codegenNamespace(allocator, entry.value_ptr.*, ns_stack, writer);
                    _ = ns_stack.pop();
                    try indent(writer, ns_stack.items.len);
                    try writer.print("}};\n", .{});
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
    ns_stack: *std.ArrayList([]const u8),
    writer: *std.io.Writer,
) !void {
    _ = allocator;
    try indent(writer, ns_stack.items.len);
    switch (type_entry.value_ptr.*) {
        .string => |str| {
            try writer.print("pub const @\"{s}\" = \"{s}\";\n", .{ type_entry.key_ptr.*, str });
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
