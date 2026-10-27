const std = @import("std");
const commands = @import("commands.zig");

pub fn nodeCapacity(node: commands.Commands.Node) usize {
    // Each child index is charged to its own node. Counts and indexes fit in two VarInt bytes.
    var size: usize = 5 + 2 + node.name.len;
    if (node.argument) |argument| {
        size += 1;
        size += switch (argument.kind) {
            .integer => @as(usize, 1) + 4 * (@as(usize, @intFromBool(argument.minimum != null)) + @intFromBool(argument.maximum != null)),
            .long => @as(usize, 1) + 8 * (@as(usize, @intFromBool(argument.minimum != null)) + @intFromBool(argument.maximum != null)),
            .boolean => 0,
            else => 1,
        };
        if (argument.suggest != null) size += 1 + "minecraft:ask_server".len;
    }
    return size;
}

pub fn treePacket(packet: anytype, tree: *const commands.Commands, visible: []const bool) ![]u8 {
    std.debug.assert(tree.count > 0 and tree.count <= 1024 and visible.len == tree.count);
    var mapping: [1024]u16 = undefined;
    var count: u16 = 0;

    for (visible[0..tree.count], mapping[0..tree.count]) |shown, *mapped| {
        mapped.* = count;
        count += @intFromBool(shown);
    }

    var writer = std.Io.Writer.fixed(packet._cursor.buffer);
    writer.end = packet._cursor.buffer.len - packet._cursor.rest.len;
    try writer.writeUleb128(count);

    for (tree.nodes[0..tree.count], 0..) |node, at| {
        if (!visible[at]) continue;

        const argument = node.argument;
        const flags: u8 = @as(u8, if (at == 0) 0 else if (argument == null) 1 else 2) | @as(u8, if (node.vtable != null) 4 else 0) | @as(u8, if (argument != null and argument.?.suggest != null) 16 else 0);
        try writer.writeByte(flags);
        var children: u16 = 0;

        var child = tree.children(@intCast(at));
        while (child.next()) |index| children += @intFromBool(visible[index]);
        try writer.writeUleb128(children);

        child = tree.children(@intCast(at));
        while (child.next()) |index|
            if (visible[index]) try writer.writeUleb128(mapping[index]);
        if (at == 0) continue;
        try string(&writer, node.name);

        if (argument) |spec| {
            const parser: u32 = switch (spec.kind) {
                .boolean => 0,
                .float => 1,
                .double => 2,
                .integer => 3,
                .long => 4,
                .players => 6,
                else => 5,
            };
            try writer.writeUleb128(parser);

            switch (spec.kind) {
                .integer, .long => {
                    try writer.writeByte(@as(u8, @intFromBool(spec.minimum != null)) | (@as(u8, @intFromBool(spec.maximum != null)) << 1));

                    if (spec.minimum) |minimum| if (spec.kind == .integer) try writer.writeInt(i32, @intCast(minimum), .big) else try writer.writeInt(i64, minimum, .big);

                    if (spec.maximum) |maximum| if (spec.kind == .integer) try writer.writeInt(i32, @intCast(maximum), .big) else try writer.writeInt(i64, maximum, .big);
                },
                .float, .double => try writer.writeByte(0),
                .boolean => {},
                .players => try writer.writeByte(2),
                else => try writer.writeUleb128(@as(u32, if (spec.kind == .greedy) 2 else 0)),
            }

            if (spec.suggest != null) try string(&writer, "minecraft:ask_server");
        }
    }

    try writer.writeUleb128(@as(u32, 0));

    return writer.buffered();
}

pub fn completions(packet: anytype, request_id: i32, text: []const u8, suggestions: *const commands.Suggestions) ![]u8 {
    var writer = std.Io.Writer.fixed(packet._cursor.buffer);
    writer.end = packet._cursor.buffer.len - packet._cursor.rest.len;
    try writer.writeUleb128(@as(u32, @bitCast(request_id)));
    try writer.writeUleb128(utf16(text[0..suggestions.start]));
    try writer.writeUleb128(utf16(text[suggestions.start..][0..suggestions.length]));
    try writer.writeUleb128(@as(u32, @intCast(suggestions.count)));

    for (suggestions.entries[0..suggestions.count]) |suggestion| {
        try string(&writer, suggestion.text);
        try writer.writeByte(@intFromBool(suggestion.tooltip.len != 0));

        if (suggestion.tooltip.len != 0) {
            try writer.writeByte(8);
            try writer.writeInt(u16, @intCast(suggestion.tooltip.len), .big);
            try writer.writeAll(suggestion.tooltip);
        }
    }

    return writer.buffered();
}

fn string(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeUleb128(@as(u32, @intCast(value.len)));
    try writer.writeAll(value);
}

fn utf16(value: []const u8) u32 {
    var count: u32 = 0;

    for (value) |byte| if (byte & 0xc0 != 0x80) {
        count += 1 + @as(u32, @intFromBool(byte >= 0xf0));
    };

    return count;
}
