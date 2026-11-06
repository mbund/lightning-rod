const std = @import("std");
const nbt = @import("nbt");

pub fn field(doc: nbt.Document, node: nbt.Node, name: []const u8) !nbt.Node {
    return node.childNamed(doc.nodes, name) orelse error.MissingNbtField;
}

pub fn integer(node: nbt.Node) !i64 {
    return switch (node.tag) {
        .byte => try node.byte(),
        .short => try node.short(),
        .int => try node.int(),
        .long => try node.long(),
        else => error.InvalidInteger,
    };
}

pub fn number(node: nbt.Node) !f64 {
    const value = switch (node.tag) {
        .float => @as(f64, try node.float()),
        .double => try node.double(),
        else => return error.InvalidNumber,
    };
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    return value;
}

pub fn optionalInt(doc: nbt.Document, node: nbt.Node, name: []const u8, default: i64) !i64 {
    return if (node.childNamed(doc.nodes, name)) |value| integer(value) else default;
}

pub fn uuid(node: nbt.Node) !u128 {
    const array = try node.intArray();
    if (array.len() != 4) return error.InvalidUuid;
    var value: u128 = 0;
    for (0..4) |index| value = (value << 32) | @as(u32, @bitCast(array.get(index)));
    return value;
}

pub fn parseUuid(text: []const u8) !u128 {
    var digits: [32]u8 = undefined;
    var count: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte == '-' and (index == 8 or index == 13 or index == 18 or index == 23) and text.len == 36) continue;
        if (!std.ascii.isHex(byte) or count == digits.len) return error.InvalidUuid;
        digits[count] = byte;
        count += 1;
    }
    if (count != digits.len) return error.InvalidUuid;
    return std.fmt.parseInt(u128, &digits, 16);
}

pub fn vector(doc: nbt.Document, node: nbt.Node) ![3]f64 {
    const info = try node.listInfo();
    if (info.len != 3) return error.InvalidPosition;
    var iterator = node.childIterator(doc.nodes);
    var result: [3]f64 = undefined;
    for (&result) |*value| value.* = try number(iterator.next().?);
    return result;
}

pub fn json(allocator: std.mem.Allocator, doc: nbt.Document, node: nbt.Node) anyerror!std.json.Value {
    return switch (node.tag) {
        .byte, .short, .int, .long => .{ .integer = try integer(node) },
        .float, .double => .{ .float = try number(node) },
        .string => .{ .string = try node.string() },
        .compound => blk: {
            var result: std.json.ObjectMap = .empty;
            var iterator = node.childIterator(doc.nodes);
            while (iterator.next()) |child| {
                if (result.contains(child.name)) return error.DuplicateNbtField;
                try result.put(allocator, child.name, try json(allocator, doc, child));
            }
            break :blk .{ .object = result };
        },
        .list => blk: {
            var result: std.array_list.Managed(std.json.Value) = .init(allocator);
            var iterator = node.childIterator(doc.nodes);
            while (iterator.next()) |child| try result.append(try json(allocator, doc, child));
            break :blk .{ .array = result };
        },
        else => error.UnsupportedNbtValue,
    };
}

test "UUID parsing rejects misplaced separators and preserves high bits" {
    const expected: u128 = 0xfedcba98765432108000123456789abc;
    try std.testing.expectEqual(expected, try parseUuid("fedcba98-7654-3210-8000-123456789abc"));
    try std.testing.expectEqual(expected, try parseUuid("fedcba98765432108000123456789abc"));
    try std.testing.expectError(error.InvalidUuid, parseUuid("fedcba987-654-3210-8000-123456789abc"));
}
