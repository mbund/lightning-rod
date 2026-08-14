const protocol = @import("protocol");
const play_decode = @import("play_decode.zig");
const registry_data = @import("registry_data");

pub const State = enum {
    handshaking,
    status,
    login,
    configuration,
    play,
};

/// Exercises the generated, zero-copy packet readers without any connection or
/// reactor state. Callers decide whether a decode error is expected.
pub fn validatePayload(state: State, payload: []const u8) !void {
    switch (state) {
        .handshaking => try validateHandshake(payload),
        .status => try validateStatus(payload),
        .login => try validateLogin(payload),
        .configuration => try validateConfiguration(payload),
        .play => try validatePlay(payload),
    }
}

fn validateHandshake(payload: []const u8) !void {
    switch (try protocol.handshaking.toServer.read(payload).name()) {
        .set_protocol => |body| {
            _, const c2 = try body.protocolVersion();
            _, const c3 = try c2.serverHost();
            _, const c4 = try c3.serverPort();
            _, const done = try c4.nextState();
            try done.finish();
        },
        else => {},
    }
}

fn validateStatus(payload: []const u8) !void {
    switch (try protocol.status.toServer.read(payload).name()) {
        .ping_start => |body| try body.finish(),
        .ping => |body| {
            _, const done = try body.time();
            try done.finish();
        },
        else => {},
    }
}

fn validateLogin(payload: []const u8) !void {
    switch (try protocol.login.toServer.read(payload).name()) {
        .login_start => |body| {
            _, const c2 = try body.username();
            _, const done = try c2.playerUUID();
            try done.finish();
        },
        .encryption_begin => |body| {
            _, const c2 = try body.sharedSecret();
            _, const done = try c2.verifyToken();
            try done.finish();
        },
        .login_acknowledged => |body| try body.finish(),
        else => {},
    }
}

fn validateConfiguration(payload: []const u8) !void {
    switch (try protocol.configuration.toServer.read(payload).name()) {
        .finish_configuration => |body| try body.finish(),
        .select_known_packs => |body| {
            const packs, const done = try body.packs();
            _ = try packs.len();
            try packs.finish();
            try done.finish();
        },
        else => {},
    }
}

fn validatePlay(payload: []const u8) !void {
    const Validator = struct {
        pub fn teleport_confirm(_: *@This(), _: u16, _: i32) void {}
        pub fn keep_alive_response(_: *@This(), _: u16, _: i64) void {}
        pub fn movement(_: *@This(), _: u16, _: ?play_decode.Position, _: ?play_decode.Rotation, _: bool) !void {}
        pub fn player_input(_: *@This(), _: u16, _: bool, _: bool) !void {}
        pub fn player_sprint(_: *@This(), _: u16, _: bool) !void {}
        pub fn player_loaded(_: *@This(), _: u16) void {}
        pub fn chat(_: *@This(), _: u16, _: []const u8) !void {}
        pub fn command(_: *@This(), _: u16, _: []const u8) !void {}
        pub fn block_dig(_: *@This(), _: u16, _: i32, _: play_decode.BlockPosition, _: i32, _: i32) !void {}
        pub fn block_place(_: *@This(), _: u16, _: play_decode.BlockPosition, _: i32, _: f32, _: f32, _: f32, _: i32) !void {}
        pub fn held_item_slot(_: *@This(), _: u16, _: i16) !void {}
        pub fn arm_animation(_: *@This(), _: u16, _: i32) !void {}
        pub fn attack_entity(_: *@This(), _: u16, _: i32) !void {}
        pub fn interact_entity(_: *@This(), _: u16, _: i32, _: i32) !void {}
        pub fn respawn(_: *@This(), _: u16) !void {}
        pub fn use_item(_: *@This(), _: u16, _: i32) !void {}
        pub fn window_click(_: *@This(), _: u16, _: i32, _: i32, _: i16, _: i8, _: i32) !void {}
        pub fn creative_slot(_: *@This(), _: u16, _: i16, _: i32, _: u8) !void {}
        pub fn close_window(_: *@This(), _: u16, _: i32) !void {}
        pub fn ignored(_: *@This(), _: u16) void {}
    };
    var validator: Validator = .{};
    try play_decode.dispatchWith(protocol, registry_data, payload, 0, &validator);
}
