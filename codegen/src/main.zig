const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const jason = try readJson(
        allocator,
        "/var/home/josh/src/lightning-rod/minecraft-data/data/pc/1.21.8/protocol.json",
    );
    defer jason.deinit();

    var stack = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer stack.deinit(allocator);

    try walkNamespaces(allocator, jason.value, &stack);
}

fn readJson(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(std.json.Value) {
    const data =
        try std.fs.cwd().readFileAlloc(allocator, path, 9999999999999);
    defer allocator.free(data);
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        data,
        .{ .allocate = .alloc_always },
    );
}

/// Recurse under every key that is not "types".
/// When hitting "types", print all its keys/values.
fn walkNamespaces(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    stack: *std.ArrayList([]const u8),
) !void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "types")) {
                    if (entry.value_ptr.* == .object) {
                        var t_it = entry.value_ptr.*.object.iterator();
                        while (t_it.next()) |t_entry| {
                            const path = try joinPath(
                                allocator,
                                stack.items,
                            );
                            defer allocator.free(path);

                            std.debug.print(
                                "{s}{s}{s} = {f}\n",
                                .{
                                    path,
                                    if (path.len > 0) "." else "",
                                    t_entry.key_ptr.*,
                                    std.json.fmt(
                                        t_entry.value_ptr.*,
                                        .{ .whitespace = .minified },
                                    ),
                                },
                            );
                        }
                    }
                } else {
                    try stack.append(allocator, entry.key_ptr.*);
                    try walkNamespaces(
                        allocator,
                        entry.value_ptr.*,
                        stack,
                    );
                    _ = stack.pop();
                }
            }
        },
        .array => |arr| {
            var i: usize = 0;
            for (arr.items) |item| {
                const idx_str =
                    try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(idx_str);

                try stack.append(allocator, idx_str);
                try walkNamespaces(allocator, item, stack);
                _ = stack.pop();

                i += 1;
            }
        },
        else => {},
    }
}

/// Join path with "." using the passed allocator.
fn joinPath(
    allocator: std.mem.Allocator,
    parts: [][]const u8,
) ![]const u8 {
    if (parts.len == 0) return allocator.dupe(u8, "");
    return try std.mem.join(allocator, ".", parts);
}
