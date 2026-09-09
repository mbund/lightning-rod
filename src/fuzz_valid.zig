const std = @import("std");
const protocol = @import("protocol");
const protocol_support = @import("protocol_support");
const validation = @import("packet_validation.zig");
const wire = @import("wire.zig");

const PacketKind = enum {
    handshake,
    status_ping,
    position_look,
    player_input,
    block_dig,
    block_place,
    held_item,
    arm_animation,
    close_window,
};

test "randomly generated valid gameplay packet bytes" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var body_storage: [256]u8 = undefined;
    const kind = smith.value(PacketKind);
    const state: validation.State, const body: []const u8 = switch (kind) {
        .handshake => body: {
            const c1 = protocol.handshaking.toServer.write(&body_storage);
            const c2 = try c1.set_protocol();
            const c3 = try c2.protocolVersion(smith.value(i32));
            const c4 = try c3.serverHost("fuzz.local");
            const c5 = try c4.serverPort(smith.value(u16));
            break :body .{ .handshaking, (try c5.nextState(smith.valueRangeAtMost(i32, 1, 2))).finish() };
        },
        .status_ping => body: {
            const c1 = protocol.status.toServer.write(&body_storage);
            const c2 = try c1.ping();
            break :body .{ .status, (try c2.time(smith.value(i64))).finish() };
        },
        .position_look => body: {
            const c1 = protocol.play.toServer.write(&body_storage);
            const c2 = try c1.position_look();
            const c3 = try c2.x(smith.value(f64));
            const c4 = try c3.y(smith.value(f64));
            const c5 = try c4.z(smith.value(f64));
            const c6 = try c5.yaw(smith.value(f32));
            const c7 = try c6.pitch(smith.value(f32));
            break :body .{ .play, (try c7.flags(.{ .onGround = smith.value(bool), .hasHorizontalCollision = smith.value(bool) })).finish() };
        },
        .player_input => body: {
            const packet = protocol.play.toServer.write(&body_storage);
            const input = try packet.player_input();
            break :body .{ .play, (try input.inputs(.{ .shift = smith.value(bool), .sprint = smith.value(bool) })).finish() };
        },
        .block_dig => body: {
            const packet = protocol.play.toServer.write(&body_storage);
            const action = try packet.block_dig();
            const location = try action.status(smith.valueRangeAtMost(i32, 0, 2));
            const face = try location.location(.{
                .x = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .z = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .y = smith.valueRangeAtMost(i16, -64, 319),
            });
            const sequence = try face.face(smith.valueRangeAtMost(i8, 0, 5));
            break :body .{ .play, (try sequence.sequence(smith.value(i32))).finish() };
        },
        .block_place => body: {
            const c1 = protocol.play.toServer.write(&body_storage);
            const c2 = try c1.block_place();
            const c3 = try c2.hand(smith.valueRangeAtMost(i32, 0, 1));
            const c4 = try c3.location(.{
                .x = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .z = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .y = smith.valueRangeAtMost(i16, -64, 319),
            });
            const c5 = try c4.direction(smith.valueRangeAtMost(i32, 0, 5));
            const c6 = try c5.cursorX(smith.value(f32));
            const c7 = try c6.cursorY(smith.value(f32));
            const c8 = try c7.cursorZ(smith.value(f32));
            const c9 = try c8.insideBlock(smith.value(bool));
            const c10 = try c9.worldBorderHit(smith.value(bool));
            break :body .{ .play, (try c10.sequence(smith.value(i32))).finish() };
        },
        .held_item => body: {
            const packet = protocol.play.toServer.write(&body_storage);
            const held = try packet.held_item_slot();
            break :body .{ .play, (try held.slotId(smith.valueRangeAtMost(i16, 0, 8))).finish() };
        },
        .arm_animation => body: {
            const packet = protocol.play.toServer.write(&body_storage);
            const arm = try packet.arm_animation();
            break :body .{ .play, (try arm.hand(smith.valueRangeAtMost(i32, 0, 1))).finish() };
        },
        .close_window => body: {
            const packet = protocol.play.toServer.write(&body_storage);
            const close = try packet.close_window();
            break :body .{ .play, (try close.windowId(smith.valueRangeAtMost(i32, 0, 127))).finish() };
        },
    };

    try validation.validatePayload(state, body);

    var framed_storage: [5 + body_storage.len]u8 = undefined;
    const after_len = try protocol_support.write_varint(&framed_storage, @intCast(body.len));
    const prefix_len = framed_storage.len - after_len.len;
    @memcpy(framed_storage[prefix_len..][0..body.len], body);
    const framed = (try wire.nextPacket(framed_storage[0 .. prefix_len + body.len])).?;
    std.debug.assert(framed.payload.len == body.len);
    try validation.validatePayload(state, framed.payload);
}
