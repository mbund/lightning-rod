const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");

const support = lightning_rod.protocol_versions.all[0];
const Protocol = lightning_rod.protocol_versions.Protocol(support.version);
const Registry = lightning_rod.protocol_versions.Registry(support.version);
const Kind = enum { movement, player_input, dig, place, held_item, arm, close_window };

test "raw and generated-valid Play input" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    if (smith.value(bool))
        try fuzzRaw({}, smith)
    else
        try fuzzValid({}, smith);
}

fn fuzzRaw(_: void, smith: *std.testing.Smith) !void {
    var storage: [16 * 1024]u8 = undefined;
    const bytes = storage[0..smith.slice(&storage)];
    var sink = Sink{};
    _ = vanilla.decodePlayPacket(Protocol, Registry, smith.value(i32), bytes, 0, &sink) catch {};
}

fn fuzzValid(_: void, smith: *std.testing.Smith) !void {
    var storage: [256]u8 = undefined;
    const id: i32, const packet: []const u8 = switch (smith.value(Kind)) {
        .movement => value: {
            const c1 = try Protocol.play.toServer.write(&storage).position_look();
            const c2 = try c1.x(smith.value(f64));
            const c3 = try c2.y(smith.value(f64));
            const c4 = try c3.z(smith.value(f64));
            const c5 = try c4.yaw(smith.value(f32));
            const c6 = try c5.pitch(smith.value(f32));
            break :value .{ Protocol.play.toServer.packetId(.position_look), (try c6.flags(.{ .onGround = smith.value(bool), .hasHorizontalCollision = smith.value(bool) })).finish() };
        },
        .player_input => value: {
            const c1 = try Protocol.play.toServer.write(&storage).player_input();
            break :value .{ Protocol.play.toServer.packetId(.player_input), (try c1.inputs(.{ .shift = smith.value(bool), .sprint = smith.value(bool) })).finish() };
        },
        .dig => value: {
            const c1 = try Protocol.play.toServer.write(&storage).block_dig();
            const c2 = try c1.status(smith.valueRangeAtMost(i32, 0, 4));
            const c3 = try c2.location(.{
                .x = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .z = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .y = smith.valueRangeAtMost(i16, -64, 319),
            });
            const c4 = try c3.face(smith.valueRangeAtMost(i8, 0, 5));
            break :value .{ Protocol.play.toServer.packetId(.block_dig), (try c4.sequence(smith.value(i32))).finish() };
        },
        .place => value: {
            const c1 = try Protocol.play.toServer.write(&storage).block_place();
            const c2 = try c1.hand(smith.valueRangeAtMost(i32, 0, 1));
            const c3 = try c2.location(.{
                .x = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .z = smith.valueRangeAtMost(i32, -30_000_000, 30_000_000),
                .y = smith.valueRangeAtMost(i16, -64, 319),
            });
            const c4 = try c3.direction(smith.valueRangeAtMost(i32, 0, 5));
            const c5 = try c4.cursorX(smith.value(f32));
            const c6 = try c5.cursorY(smith.value(f32));
            const c7 = try c6.cursorZ(smith.value(f32));
            const c8 = try c7.insideBlock(smith.value(bool));
            const c9 = try c8.worldBorderHit(smith.value(bool));
            break :value .{ Protocol.play.toServer.packetId(.block_place), (try c9.sequence(smith.value(i32))).finish() };
        },
        .held_item => value: {
            const c1 = try Protocol.play.toServer.write(&storage).held_item_slot();
            break :value .{ Protocol.play.toServer.packetId(.held_item_slot), (try c1.slotId(smith.valueRangeAtMost(i16, 0, 8))).finish() };
        },
        .arm => value: {
            const c1 = try Protocol.play.toServer.write(&storage).arm_animation();
            break :value .{ Protocol.play.toServer.packetId(.arm_animation), (try c1.hand(smith.valueRangeAtMost(i32, 0, 1))).finish() };
        },
        .close_window => value: {
            const c1 = try Protocol.play.toServer.write(&storage).close_window();
            break :value .{ Protocol.play.toServer.packetId(.close_window), (try c1.windowId(smith.valueRangeAtMost(i32, 0, 127))).finish() };
        },
    };
    var sink = Sink{};
    try std.testing.expect(try vanilla.decodePlayPacket(Protocol, Registry, id, body(packet), 0, &sink));
    try std.testing.expectEqual(@as(u8, 1), sink.calls);
}

fn body(packet: []const u8) []const u8 {
    for (0..@min(packet.len, 5)) |index| if (packet[index] & 0x80 == 0) return packet[index + 1 ..];
    unreachable;
}

const Sink = struct {
    calls: u8 = 0,

    fn hit(self: *Sink) void {
        self.calls +|= 1;
    }

    pub fn teleport_confirm(self: *Sink, _: u16, _: i32) !void { self.hit(); }
    pub fn keep_alive_response(self: *Sink, _: u16, _: i64) !void { self.hit(); }
    pub fn chunk_batch_received(self: *Sink, _: u16, _: f32) !void { self.hit(); }
    pub fn movement(self: *Sink, _: u16, _: ?lightning_rod.geometry.Vec3, _: ?lightning_rod.geometry.Rotation, _: bool) !void { self.hit(); }
    pub fn player_input(self: *Sink, _: u16, _: bool, _: bool) !void { self.hit(); }
    pub fn player_sprint(self: *Sink, _: u16, _: bool) !void { self.hit(); }
    pub fn player_loaded(self: *Sink, _: u16) !void { self.hit(); }
    pub fn chat(self: *Sink, _: u16, _: []const u8) !void { self.hit(); }
    pub fn command(self: *Sink, _: u16, _: []const u8) !void { self.hit(); }
    pub fn block_dig(self: *Sink, _: u16, _: i32, _: lightning_rod.geometry.BlockPos, _: i32, _: i32) !void { self.hit(); }
    pub fn block_place(self: *Sink, _: u16, _: lightning_rod.geometry.BlockPos, _: i32, _: f32, _: f32, _: f32, _: i32) !void { self.hit(); }
    pub fn held_item_slot(self: *Sink, _: u16, _: i16) !void { self.hit(); }
    pub fn arm_animation(self: *Sink, _: u16, _: i32) !void { self.hit(); }
    pub fn attack_entity(self: *Sink, _: u16, _: i32) !void { self.hit(); }
    pub fn interact_entity(self: *Sink, _: u16, _: i32, _: i32) !void { self.hit(); }
    pub fn respawn(self: *Sink, _: u16) !void { self.hit(); }
    pub fn use_item(self: *Sink, _: u16, _: i32, _: i32, _: lightning_rod.geometry.Rotation) !void { self.hit(); }
    pub fn window_click(self: *Sink, _: u16, _: i32, _: i32, _: i16, _: i8, _: i32) !void { self.hit(); }
    pub fn creative_slot(self: *Sink, _: u16, _: i16, _: i32, _: u8) !void { self.hit(); }
    pub fn close_window(self: *Sink, _: u16, _: i32) !void { self.hit(); }
    pub fn ignored(self: *Sink, _: u16) void { self.hit(); }
};
