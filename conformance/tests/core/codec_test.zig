const std = @import("std");
const mcc = @import("mccore");

fn field(packet: mcc.Packet, name: []const u8) ?[]const u8 {
    for (packet.fields) |entry|
        if (std.mem.eql(u8, entry.name, name)) return entry.value.literal;
    return null;
}

test "cached codec ABI round-trips typed input for every supported schema" {
    const fields = [_]mcc.Field{
        .{ .name = "x", .value = .{ .literal = "12.5" } },
        .{ .name = "y", .value = .{ .literal = "70" } },
        .{ .name = "z", .value = .{ .literal = "-3.25" } },
        .{ .name = "on_ground", .value = .{ .literal = "1" } },
    };
    const packet = mcc.Packet{ .name = "move", .fields = &fields };
    for ([_][]const u8{ "1.21.6", "1.21.8" }) |minecraft| {
        var codec = try mcc.canonicalizer.Canonicalizer.initForMinecraftWithAllocator(
            &.{},
            minecraft,
            std.testing.allocator,
        );
        defer codec.deinit();
        var bytes: [128]u8 = undefined;
        const encoded = try codec.encodePacket(&bytes, packet);
        const decoded = (try codec.canonicalizeServerbound(encoded)).?;
        try std.testing.expectEqualStrings("move", decoded.name);
        try std.testing.expectEqualStrings("12.5", field(decoded, "x").?);
        try std.testing.expectEqualStrings("70", field(decoded, "y").?);
        try std.testing.expectEqualStrings("-3.25", field(decoded, "z").?);
        try std.testing.expectEqualStrings("1", field(decoded, "on_ground").?);
    }
}

test "cached codec canonicalizes clientbound identities through its opaque handle" {
    const identities = [_]mcc.Identity{.{
        .alias = "zombie",
        .entity_id = 42,
        .uuid = 0x0102_0304_0506_0708_1112_1314_1516_1718,
    }};
    var codec = mcc.canonicalizer.Canonicalizer.initWithAllocator(&identities, std.testing.allocator);
    defer codec.deinit();

    // 1.21.6-1.21.8 clientbound entity_destroy: packet id, count, entity id.
    const payload = [_]u8{ 70, 1, 42 };
    const output = (try codec.canonicalize(.{
        .recipient = "alice",
        .payload = &payload,
    })).?;
    try std.testing.expectEqualStrings("alice", output.recipient);
    try std.testing.expectEqualStrings("entity_destroy", output.packet.name);
    try std.testing.expectEqualStrings("zombie", field(output.packet, "subjects").?);
}

test "cached codec ABI fingerprint covers public aggregate layout" {
    const abi = mcc.codec_abi;
    try std.testing.expectEqual(@sizeOf(usize) * 2, @sizeOf(abi.Slice));
    try std.testing.expectEqual(@sizeOf(abi.Slice) * 2, @sizeOf(abi.Field));
    try std.testing.expect(abi.layout_fingerprint != 0);
}
