const protocol = @import("protocol");

pub const State = enum {
    handshaking,
    status,
    login,
    configuration,
    play,
};

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
    _ = try protocol.play.toServer.read(payload).name();
}
